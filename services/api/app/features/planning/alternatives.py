"""Alternatives for a place that does not work (docs/ALTERNATIVE_PLACES_PLAN.md).

Pure functions: no model, no network, no database. For a place that causes a conflict or
fails a check, find catalog places nearby, rank them by how alike they are, and keep only
those that survive a rebuild of the traveler's own itinerary with the swap in place.

Rules that matter:

- Nothing is invented. A recorded unfavourable fact removes a candidate; a missing fact
  never removes it and never counts as a pass, it lowers the rank and is named.
- A candidate is shown only if the original problem is gone and the swap causes no new
  conflict and no newly failed check.
- One place is replaced at a time, at the same position. Nothing is applied here.
"""

from dataclasses import dataclass, field, replace
from datetime import date

from app.features.destinations.hours import clock_text, hours_on
from app.features.planning.draft import _haversine_km
from app.features.planning.timeline import (
    ESTIMATE_DETOUR,
    ESTIMATE_SPEED_KMH,
    LegInfo,
    StopInfo,
    TimelineInput,
    build_timeline,
)
from app.features.planning.timeline_schemas import Timeline

NEAR_KM, FAR_KM = 15.0, 30.0
MAX_ALTERNATIVES = 3
MAX_TESTS = 30  # rebuilds per place: ranking first keeps this far below the pool size
# A check that names places and can fail because of one of them.
_PLACE_CHECKS = ("opening_hours", "operating_status", "activity_suitability")
_BUDGET_ORDER = {"budget": 0, "low": 0, "mid_range": 1, "midrange": 1, "moderate": 1,
                 "premium": 2, "luxury": 2, "high": 2}


@dataclass
class PlaceProfile:
    """What ranking needs to know about a place, beyond what the timeline holds."""

    stop: StopInfo
    lat: float | None = None
    lng: float | None = None
    island: bool = False
    category: str | None = None
    vibes: str | None = None
    activities: str | None = None
    budget_class: str | None = None
    kid_friendly: bool | None = None
    elderly_friendly: bool | None = None
    wheelchair_accessible: bool | None = None


@dataclass
class Alternative:
    destination_id: int
    name: str
    distance_km: float
    reasons: list[str]  # plain words: why it was offered
    unverified: list[str]  # what is not recorded, never reported as fine
    timeline: Timeline  # the whole itinerary with the swap in place


@dataclass
class AlternativeSet:
    destination_id: int  # the place that does not work
    name: str
    problems: list[str]  # the conflicts and failed checks that name it
    options: list[Alternative] = field(default_factory=list)


# ---- which places do not work -----------------------------------------------------------


def _problems(timeline: Timeline) -> dict[int, list[str]]:
    found: dict[int, list[str]] = {}
    for conflict in timeline.conflicts:
        if conflict.destination_id is not None:
            found.setdefault(conflict.destination_id, []).append(conflict.message)
    for check in timeline.checks:
        if check.status == "failed" and check.id in _PLACE_CHECKS:
            for destination_id in check.destination_ids:
                found.setdefault(destination_id, []).append(check.message)
    return found


# ---- candidates -------------------------------------------------------------------------


def _tokens(text: str | None) -> set[str]:
    return {t.strip().lower() for t in (text or "").replace(";", ",").split(",") if t.strip()}


def _km(a: PlaceProfile, b: PlaceProfile) -> float | None:
    if None in (a.lat, a.lng, b.lat, b.lng):
        return None
    return _haversine_km(float(a.lat), float(a.lng), float(b.lat), float(b.lng))


def _removed(candidate: PlaceProfile, needs: set[str]) -> bool:
    """A recorded fact that rules the candidate out. A missing fact never does."""
    stop = candidate.stop
    if stop.operating_status in {"temporarily_closed", "permanently_closed"}:
        return True
    if stop.in_region is False or candidate.island:
        return True
    return ((("wheelchair" in needs and candidate.wheelchair_accessible is False)
             or ("elderly" in needs and candidate.elderly_friendly is False)
             or ("kids" in needs and candidate.kid_friendly is False)))


def _score(failing: PlaceProfile, cand: PlaceProfile, km: float, needs: set[str]) -> float:
    score = 3.0 * bool(_tokens(failing.category) & _tokens(cand.category))
    score += min(2, len(_tokens(failing.vibes) & _tokens(cand.vibes)))
    score += min(2, len(_tokens(failing.activities) & _tokens(cand.activities)))
    mine = _BUDGET_ORDER.get((failing.budget_class or "").lower())
    theirs = _BUDGET_ORDER.get((cand.budget_class or "").lower())
    if mine is not None and theirs is not None:
        score += 1 if theirs <= mine else -1
    flags = {"wheelchair": cand.wheelchair_accessible, "elderly": cand.elderly_friendly,
             "kids": cand.kid_friendly}
    score += sum(1 for need in needs if flags.get(need) is True)
    score += 2 * cand.stop.hours.structured
    return score - km / NEAR_KM


# ---- the swap ---------------------------------------------------------------------------


def _estimate(a: PlaceProfile, b: PlaceProfile) -> LegInfo | None:
    if a.island or b.island:
        return None
    km = _km(a, b)
    if km is None:
        return None
    return LegInfo(round(km * ESTIMATE_DETOUR / ESTIMATE_SPEED_KMH * 60), "estimated")


def _swapped(
    inp: TimelineInput, failing_id: int, cand: PlaceProfile,
    profiles: dict[int, PlaceProfile], origin: PlaceProfile | None,
) -> TimelineInput:
    """The same itinerary with the candidate in the failing place's position."""
    order = [s.destination_id for s in inp.stops]
    index = order.index(failing_id)
    stops = list(inp.stops)
    stops[index] = cand.stop
    legs = {k: v for k, v in inp.legs.items() if failing_id not in k}
    previous = profiles.get(order[index - 1]) if index > 0 else origin
    following = profiles.get(order[index + 1]) if index + 1 < len(order) else (
        origin if inp.return_to_origin else None)
    previous_id = order[index - 1] if index > 0 else None
    following_id = order[index + 1] if index + 1 < len(order) else None
    if previous is not None and (leg := _estimate(previous, cand)) is not None:
        legs[(previous_id, cand.stop.destination_id)] = leg
    if following is not None and (leg := _estimate(cand, following)) is not None:
        legs[(cand.stop.destination_id, following_id)] = leg
    if inp.lodging is not None:
        home = profiles.get(inp.lodging.destination_id)
        if home is not None and (leg := _estimate(home, cand)) is not None:
            legs[(home.stop.destination_id, cand.stop.destination_id)] = leg
            legs[(cand.stop.destination_id, home.stop.destination_id)] = leg
    pins = [p for p in inp.pins if p.destination_id != failing_id]
    return replace(inp, stops=stops, legs=legs, pins=pins)


def _survives(before: Timeline, after: Timeline, cand_id: int) -> bool:
    """The problem is gone and nothing new broke."""
    if any(c.destination_id == cand_id for c in after.conflicts):
        return False
    if any(cand_id in c.destination_ids for c in after.checks if c.status == "failed"):
        return False
    old = {(c.code, c.destination_id) for c in before.conflicts}
    if any((c.code, c.destination_id) not in old and c.destination_id != cand_id
           for c in after.conflicts if c.destination_id is not None):
        return False
    failed_before = {c.id for c in before.checks if c.status == "failed"}
    return all(c.id in failed_before for c in after.checks if c.status == "failed")


def _hours_note(stop: StopInfo, start: date | None) -> tuple[str | None, str | None]:
    """(a reason, or what is not recorded) from the recorded hours on the travel date."""
    if start is None:
        return None, "No travel date is set, so opening days cannot be checked."
    state, windows = hours_on(start, stop.hours.open_24_hours, stop.hours.weekly,
                              stop.hours.exceptions)
    if state == "open_24_hours":
        return "Open 24 hours", None
    if state == "open" and windows:
        text = ", ".join(f"{clock_text(a)} to {clock_text(b)}" for a, b in windows)
        return f"Open {start:%A} {text}", None
    return None, "Opening hours are not confirmed."


def _reasons(
    failing: PlaceProfile, cand: PlaceProfile, km: float, needs: set[str], start: date | None,
) -> tuple[list[str], list[str]]:
    reasons, unverified = [], []
    if _tokens(failing.category) & _tokens(cand.category):
        reasons.append("Same kind of place")
    elif _tokens(failing.vibes) & _tokens(cand.vibes):
        reasons.append("A similar feel")
    reasons.append(f"{km:.1f} km from {failing.stop.name}")
    open_note, missing = _hours_note(cand.stop, start)
    if open_note:
        reasons.append(open_note)
    if missing:
        unverified.append(missing)
    for need, flag, label in (("wheelchair", cand.wheelchair_accessible, "Wheelchair access"),
                              ("elderly", cand.elderly_friendly, "Suitability for older travelers"),
                              ("kids", cand.kid_friendly, "Suitability for children")):
        if need in needs:
            (reasons if flag else unverified).append(
                f"{label} is recorded" if flag else f"{label} is not recorded")
    return reasons, unverified


# ---- the entry point --------------------------------------------------------------------


def find_alternatives(
    inp: TimelineInput,
    profiles: dict[int, PlaceProfile],
    pool: list[PlaceProfile],
    *,
    timeline: Timeline | None = None,
    needs: set[str] | None = None,
    origin: PlaceProfile | None = None,
) -> list[AlternativeSet]:
    """For each place that does not work, up to three tested replacements.

    `profiles` holds the itinerary's own places, `pool` the catalog places that are not in
    it, `needs` the group's recorded needs ("wheelchair", "elderly", "kids"), `origin` the
    starting point (for the first and the return leg). A place that is the lodging is
    never replaced, and a place with no replacement that survives gets an empty list.
    """
    needs = needs or set()
    before = timeline or build_timeline(inp)
    in_trip = {s.destination_id for s in inp.stops}
    lodging_id = inp.lodging.destination_id if inp.lodging else None
    result = []
    for failing_id, problems in _problems(before).items():
        failing = profiles.get(failing_id)
        if failing is None or failing_id not in in_trip or failing_id == lodging_id:
            continue
        entry = AlternativeSet(failing_id, failing.stop.name, problems)
        ranked = []
        for cand in pool:
            if cand.stop.destination_id in in_trip or _removed(cand, needs):
                continue
            km = _km(failing, cand)
            if km is None or km > FAR_KM:
                continue
            ranked.append((_score(failing, cand, km, needs), km, cand))
        ranked.sort(key=lambda r: (-r[0], r[1], r[2].stop.destination_id))
        seen: set[int] = set()  # tested in the near pass: not rebuilt in the far one
        for limit in (NEAR_KM, FAR_KM):
            for _, km, cand in ranked:
                if len(entry.options) >= MAX_ALTERNATIVES or len(seen) >= MAX_TESTS:
                    break
                if km > limit or cand.stop.destination_id in seen:
                    continue
                seen.add(cand.stop.destination_id)
                after = build_timeline(_swapped(inp, failing_id, cand, profiles, origin))
                if not _survives(before, after, cand.stop.destination_id):
                    continue
                reasons, unverified = _reasons(failing, cand, km, needs, inp.start_date)
                entry.options.append(Alternative(
                    cand.stop.destination_id, cand.stop.name, round(km, 1), reasons,
                    unverified, after))
            if len(entry.options) >= MAX_ALTERNATIVES:
                break
        result.append(entry)
    return result

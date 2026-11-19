"""Deterministic checks on a built timeline (specification B8).

Each check is passed, failed or cannot verify. Missing information never passes: a place
with no structured hours cannot be verified, a leg with no travel time cannot be verified.
Checks that do not apply (no return deadline, no children) are left out rather than
reported as passed.
"""

from decimal import Decimal

from app.features.planning.timeline_schemas import (
    BudgetSummary,
    Check,
    Conflict,
    TimelineDay,
)


def _ids(*groups) -> list[int]:
    seen: list[int] = []
    for group in groups:
        for value in group:
            if value is not None and value not in seen:
                seen.append(value)
    return seen


def build_checks(inp, days: list[TimelineDay], conflicts: list[Conflict], meta, budget: BudgetSummary):
    checks: list[Check] = []
    items = [item for day in days for item in day.items]
    stops = {s.destination_id: s for s in inp.stops}

    # 1. Chronological order and overlaps, day by day.
    problems = []
    for day in days:
        previous_end = None
        for item in day.items:
            if item.starts_at is None:
                continue
            if previous_end is not None and item.starts_at < previous_end:
                problems.append(f"day {day.day}: {item.label} starts before the previous item ends")
            if item.ends_at is not None:
                previous_end = item.ends_at
    checks.append(Check(
        id="chronological_order",
        status="failed" if problems else "passed",
        message="; ".join(problems) if problems else "Items are in order and do not overlap.",
    ))

    # 2. The traveler's picks: all present, no extra places.
    visited = {i.destination_id for i in items if i.kind == "visit"}
    picks = set(stops)
    missing, extra = picks - visited, visited - picks
    checks.append(Check(
        id="selected_places",
        status="failed" if missing or extra else "passed",
        message=("Every selected place is in the itinerary." if not missing and not extra
                 else "The itinerary does not match the selected places."),
        destination_ids=_ids(sorted(missing), sorted(extra)),
    ))

    # 3. The travel date, which hours and weekdays depend on.
    if inp.start_date is None:
        checks.append(Check(
            id="travel_date", status="cannot_verify",
            message="No travel date is set, so opening days cannot be checked."))
    else:
        checks.append(Check(
            id="travel_date", status="passed",
            message=f"Travel starts on {inp.start_date:%A %d %B %Y}."))

    # 4. Geographic scope.
    outside = [s.destination_id for s in inp.stops if s.in_region is False]
    unknown_region = [s.destination_id for s in inp.stops if s.in_region is None]
    if outside:
        checks.append(Check(id="geographic_scope", status="failed",
                            message="Some places are outside the Davao Region.",
                            destination_ids=outside))
    elif unknown_region:
        checks.append(Check(id="geographic_scope", status="cannot_verify",
                            message="The region of some places is not recorded.",
                            destination_ids=unknown_region))
    else:
        checks.append(Check(id="geographic_scope", status="passed",
                            message="All places are inside the Davao Region."))

    # 5. Place status (open at all).
    closed = [s.destination_id for s in inp.stops
              if s.operating_status in {"temporarily_closed", "permanently_closed"}]
    unknown_status = [s.destination_id for s in inp.stops if s.operating_status is None]
    if closed:
        checks.append(Check(id="operating_status", status="failed",
                            message="Some places are recorded as closed.",
                            destination_ids=closed))
    elif unknown_status:
        checks.append(Check(id="operating_status", status="cannot_verify",
                            message="Whether some places are open at all is not recorded.",
                            destination_ids=unknown_status))
    else:
        checks.append(Check(id="operating_status", status="passed",
                            message="All places are recorded as open."))

    # 6. Opening hours and last admission.
    failed_hours = [i for i, m in meta.items() if m.hours == "failed" and i not in closed]
    unverified_hours = [i for i, m in meta.items() if m.hours == "unverified"]
    if failed_hours:
        checks.append(Check(id="opening_hours", status="failed",
                            message="Some visits do not fit the opening hours.",
                            destination_ids=failed_hours))
    elif unverified_hours:
        checks.append(Check(id="opening_hours", status="cannot_verify",
                            message=(f"Opening hours are not confirmed for "
                                     f"{len(unverified_hours)} stop(s)."),
                            destination_ids=unverified_hours))
    else:
        checks.append(Check(id="opening_hours", status="passed",
                            message="Every visit fits its recorded opening hours."))

    # 7. Travel times.
    legs = [i.travel for i in items if i.kind == "travel" and i.travel]
    unknown_legs = [leg for leg in legs if leg.minutes is None]
    estimated_legs = [leg for leg in legs if leg.minutes is not None and leg.basis != "supported"]
    if unknown_legs:
        checks.append(Check(id="travel_times", status="cannot_verify",
                            message=(f"{len(unknown_legs)} travel leg(s) have no travel time: "
                                     + ", ".join(f"{leg.from_label} to {leg.to_label}"
                                                 for leg in unknown_legs) + ".")))
    elif estimated_legs:
        checks.append(Check(id="travel_times", status="cannot_verify",
                            message=(f"{len(estimated_legs)} travel leg(s) are estimated from "
                                     "straight-line distance, not a route.")))
    elif legs:
        checks.append(Check(id="travel_times", status="passed",
                            message="Every travel leg has a route-based time."))

    # 8. Visit durations.
    defaults = [i for i, m in meta.items() if m.duration_basis == "planning_default"]
    if defaults:
        checks.append(Check(id="visit_durations", status="cannot_verify",
                            message=(f"{len(defaults)} stop(s) use a planning default visit "
                                     "length: none is recorded."),
                            destination_ids=defaults))
    elif inp.stops:
        checks.append(Check(id="visit_durations", status="passed",
                            message="Every visit length is recorded."))

    # 9. Return deadline.
    if inp.return_deadline is not None and inp.return_to_origin:
        returned = next((i for i in items if i.kind == "return"), None)
        late = any(c.code == "after_return_deadline" for c in conflicts)
        if late:
            checks.append(Check(id="return_deadline", status="failed",
                                message="The return arrives after the deadline."))
        elif returned is None:
            checks.append(Check(id="return_deadline", status="cannot_verify",
                                message="The return has no travel time, so the arrival "
                                        "cannot be compared with the deadline."))
        else:
            checks.append(Check(id="return_deadline", status="passed",
                                message="The return arrives before the deadline."))

    # 10. Suitability for the children in the group.
    if inp.child_ages:
        youngest = min(inp.child_ages)
        too_young = [s.destination_id for s in inp.stops
                     if s.min_age is not None and youngest < s.min_age]
        unrecorded = [s.destination_id for s in inp.stops if s.min_age is None]
        if too_young:
            checks.append(Check(id="activity_suitability", status="failed",
                                message="A child is younger than a recorded minimum age.",
                                destination_ids=too_young))
        elif unrecorded:
            checks.append(Check(id="activity_suitability", status="cannot_verify",
                                message="Age limits are not recorded for some places.",
                                destination_ids=unrecorded))
        else:
            checks.append(Check(id="activity_suitability", status="passed",
                                message="Every recorded age limit is met."))

    # 11. Budget arithmetic and traveler counts.
    recomputed = Decimal("0")
    counted = True
    for item in items:
        for cost in item.costs:
            if cost.included_in or cost.amount is None:
                continue
            if cost.scope == "per_person":
                if inp.traveler_count is None:
                    counted = False
                    continue
                recomputed += cost.amount * inp.traveler_count
            else:
                recomputed += cost.amount
    if not counted:
        checks.append(Check(id="budget_arithmetic", status="cannot_verify",
                            message="The traveler count is missing, so per-person costs "
                                    "cannot be added up."))
    elif recomputed != budget.subtotal:
        checks.append(Check(id="budget_arithmetic", status="failed",
                            message="The costs do not add up to the subtotal."))
    else:
        checks.append(Check(id="budget_arithmetic", status="passed",
                            message="The known and estimated costs add up to the subtotal."))
    return checks

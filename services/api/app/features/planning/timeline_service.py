"""Builds a timeline from a trip state and the catalog (docs/ITINERARY_TIMELINE_DESIGN.md, T2).

Looks up the picks' records (structured hours, prices, visit lengths, booking notes), the
route result from the existing preview, and the traveler's budget lines, hands them to the
pure engine in timeline.py, and explains what changed when a previous timeline is given.
Nothing is saved.
"""

from decimal import Decimal

from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.features.destinations.hours import clock_text
from app.features.destinations.models import (
    DestinationHourException,
    DestinationHours,
    DestinationPrice,
)
from app.features.destinations.prices import money_text
from app.features.destinations.region import region_status
from app.features.planning.draft import _haversine_km
from app.features.planning.schemas import PlanningPreviewRequest, PlanningState
from app.features.planning.service import PlanningService
from app.features.planning.timeline import (
    CostInfo,
    HoursInfo,
    LegInfo,
    Lodging,
    Pin,
    StopInfo,
    TimelineInput,
    build_timeline,
)
from app.features.planning.timeline_schemas import (
    Check,
    Timeline,
    TimelineRequest,
    TimelineResponse,
)
from app.features.routes.service import RouteService

# A straight-line estimate is only a planning basis: an assumed average road speed with a
# detour factor. It is labelled "estimated" and never used for a place on an island.
ESTIMATE_SPEED_KMH = 35.0
ESTIMATE_DETOUR = 1.3
_BUDGET_CATEGORIES = {"transportation", "accommodation", "food", "other"}
_STATUS_FROM_SOURCE = {
    "catalog_price_with_verified_basis": "known",
    "traveler_age_pricing_rule": "estimated",
}


# ---- prices -----------------------------------------------------------------------------


def _group(state: PlanningState) -> tuple[int | None, list[int]]:
    """(number of adults, child ages); adults None when it cannot be worked out."""
    children = list(state.child_ages)
    if state.adult_count is not None:
        return state.adult_count, children
    if state.traveler_count is not None:
        return max(0, state.traveler_count - len(children)), children
    return None, children


def stop_costs(destination, prices: list, state: PlanningState) -> list[CostInfo]:
    """Entrance costs for the group from recorded prices; unknown stays unknown."""
    entrance = [p for p in prices if p.item == "entrance"]
    status = "known" if destination.fees_verified_at is not None else "estimated"
    adults, children = _group(state)
    if not entrance:
        if destination.estimated_cost is not None:
            return [CostInfo("Catalog estimate (charging basis not recorded)",
                             destination.estimated_cost, "estimated", scope="per_person",
                             basis_recorded=False)]
        text = f" (listed only as text: {destination.entrance_fee})" if destination.entrance_fee else ""
        return [CostInfo(f"Entrance fee{text}", None, "unknown")]
    if adults is None:
        return [CostInfo("Entrance fee: the group size is not set", None, "unknown")]

    def total(row, count: int) -> Decimal:
        # per group or per vehicle is charged once, not per head.
        return row.amount if row.unit in {"per_group", "per_vehicle"} else row.amount * count

    everyone = next((p for p in entrance if p.audience == "everyone"), None)
    adult = next((p for p in entrance if p.audience == "adult"), None) or everyone
    costs: list[CostInfo] = []
    if adults:
        if adult is None:
            costs.append(CostInfo(f"Entrance for {adults} adult(s): no adult price recorded",
                                  None, "unknown"))
        else:
            costs.append(CostInfo(
                f"Entrance: {adults} adult(s) x {money_text(adult.amount)}",
                total(adult, adults), status))
    for age in sorted(set(children)):
        count = children.count(age)
        row = next((p for p in entrance if p.audience == "child"
                    and (p.age_min is None or p.age_min <= age)
                    and (p.age_max is None or age <= p.age_max)), None) or everyone
        if row is None:
            costs.append(CostInfo(f"Entrance for {count} child(ren) aged {age}: no price "
                                  "recorded", None, "unknown"))
        else:
            costs.append(CostInfo(
                f"Entrance: {count} child(ren) aged {age} x {money_text(row.amount)}",
                total(row, count), status))
    return costs


# ---- legs -------------------------------------------------------------------------------


def _legs(preview, destinations, state, lodging: Lodging | None = None) -> dict:
    """Route legs when a route was calculated, else straight-line estimates where safe."""
    legs: dict[tuple[int | None, int | None], LegInfo] = {}
    summary = preview.route.summary if preview.route.status == "calculated" else None
    if summary is not None:
        for leg in summary.legs:
            legs[(leg.from_destination_id, leg.to_destination_id)] = LegInfo(
                leg.duration_minutes, "estimated" if leg.is_estimated else "supported",
                summary.travel_mode, summary.arrival_points_verified)
    points = [(None, state.origin.lat, state.origin.lng) if state.origin else (None, None, None)]
    points += [(d.destination_id, d.lat, d.lng) for d in destinations]
    islands = {d.destination_id for d in destinations if d.island_group}
    pairs = list(zip(points, points[1:]))
    if state.return_to_origin and destinations:
        pairs.append((points[-1], points[0]))
    for (a_id, a_lat, a_lng), (b_id, b_lat, b_lng) in pairs:
        key = (a_id, b_id)
        if key in legs or a_id in islands or b_id in islands:
            continue
        if None in (a_lat, a_lng, b_lat, b_lng):
            continue
        km = _haversine_km(float(a_lat), float(a_lng), float(b_lat), float(b_lng))
        minutes = round(km * ESTIMATE_DETOUR / ESTIMATE_SPEED_KMH * 60)
        legs[key] = LegInfo(minutes, "estimated")
    if lodging is not None:
        # To and from the place to stay, which the route (a chain of the picks) does not
        # cover: straight-line estimates, labelled as such.
        home = next((d for d in destinations if d.destination_id == lodging.destination_id), None)
        if home is not None and home.lat is not None and home.lng is not None                 and home.destination_id not in islands:
            for d in destinations:
                if d.destination_id == home.destination_id or d.destination_id in islands                         or d.lat is None or d.lng is None:
                    continue
                km = _haversine_km(float(home.lat), float(home.lng), float(d.lat), float(d.lng))
                minutes = round(km * ESTIMATE_DETOUR / ESTIMATE_SPEED_KMH * 60)
                legs.setdefault((home.destination_id, d.destination_id), LegInfo(minutes, "estimated"))
                legs.setdefault((d.destination_id, home.destination_id), LegInfo(minutes, "estimated"))
    return legs


def _lodging(preview) -> tuple[Lodging | None, str | None]:
    """The place the group sleeps, from the stay they chose; unclear stays are not guessed."""
    stays = [o for o in preview.accommodation_options if o.selected]
    places = {o.destination_id for o in stays}
    if len(places) == 1:
        return Lodging(stays[0].destination_id, stays[0].name), None
    if len(places) > 1:
        return None, ("More than one stay is chosen, and which night is spent where is not "
                      "set.")
    return None, None


# ---- the adapter ------------------------------------------------------------------------


async def _records(session: AsyncSession, ids: list[int]):
    if not ids:
        return {}, {}, {}
    hours = (await session.execute(
        select(DestinationHours).where(DestinationHours.destination_id.in_(ids)))).scalars().all()
    exceptions = (await session.execute(select(DestinationHourException).where(
        DestinationHourException.destination_id.in_(ids)))).scalars().all()
    prices = (await session.execute(
        select(DestinationPrice).where(DestinationPrice.destination_id.in_(ids)))).scalars().all()

    def group(rows):
        grouped: dict[int, list] = {}
        for row in rows:
            grouped.setdefault(row.destination_id, []).append(row)
        return grouped

    return group(hours), group(exceptions), group(prices)


# Missing-cost codes from the preview budget, sorted by what they mean for a traveler.
# A cost we can name becomes one unknown line; a request for input becomes a prompt; the
# rest (entrance and child prices, handled per stop) are left out.
_UNKNOWN_COST_LABELS = {
    "food_allowance_missing": "Food (no allowance set)",
    "activity_allowance_missing": "Activity fees (no allowance set)",
    "transport_selection_missing": "Transport (cost not set)",
    "transport_price_basis_missing": "Transport (cost not set)",
    "transport_connections_missing": "Transport (cost not set)",
    "transport_outbound_missing": "Transport (cost not set)",
    "transport_return_missing": "Transport (cost not set)",
    "fuel_estimate_missing": "Fuel and vehicle expenses (not set)",
    "vehicle_expense_allowance_missing": "Fuel and vehicle expenses (not set)",
    "accommodation_selection_missing": "Accommodation (cost not set)",
    "accommodation_price_basis_missing": "Accommodation (cost not set)",
}
_PROMPT_CODES = {
    "trip_details_missing", "destination_selection_missing", "selection_invalid",
    "allowance_conflict", "accommodation_nights_mismatch",
}


def _trip_costs(preview) -> tuple[list[CostInfo], str | None, list[str]]:
    costs: list[CostInfo] = []
    covered_by: str | None = None
    prompts: list[str] = []
    for line in preview.budget.lines:
        if line.category not in _BUDGET_CATEGORIES:
            continue
        if line.category == "food":
            covered_by = "your food allowance"
        status = _STATUS_FROM_SOURCE.get(line.source, "estimated")
        costs.append(CostInfo(
            line.label, line.amount, status,
            included_in=line.included_in if line.source == "included_in_allowance" else None))
    named: set[str] = set()
    for missing in preview.budget.missing_costs:
        label = _UNKNOWN_COST_LABELS.get(missing.code)
        if label is not None:
            if label not in named:
                named.add(label)
                costs.append(CostInfo(label, None, "unknown"))
        elif missing.code in _PROMPT_CODES and missing.message not in prompts:
            prompts.append(missing.message)
    return costs, covered_by, prompts


async def build_timeline_response(
    session: AsyncSession, route_service: RouteService | None, data: TimelineRequest,
) -> TimelineResponse:
    state = data.state
    preview = await PlanningService(session, route_service).preview(
        PlanningPreviewRequest(state=state, input_revision=data.input_revision))
    from app.features.planning.repository import PlanningRepository

    destinations = await PlanningRepository(session).list_active_destinations(
        state.destination_ids)
    by_id = {d.destination_id: d for d in destinations}
    ordered = [by_id[i] for i in state.destination_ids if i in by_id]
    unavailable = [i for i in state.destination_ids if i not in by_id]
    hours, exceptions, prices = await _records(session, [d.destination_id for d in ordered])

    stops = []
    for d in ordered:
        region = region_status(d.lat, d.lng)
        stops.append(StopInfo(
            destination_id=d.destination_id, name=d.name,
            typical_visit_min_minutes=d.typical_visit_min_minutes,
            typical_visit_max_minutes=d.typical_visit_max_minutes,
            stay_duration_type=d.stay_duration_type,
            hours=HoursInfo(
                open_24_hours=d.open_24_hours, weekly=hours.get(d.destination_id, []),
                exceptions=exceptions.get(d.destination_id, []), text=d.operating_hours),
            operating_status=d.operating_status, booking_requirement=d.booking_requirement,
            booking_note=d.booking_note,
            in_region=True if region == "inside" else False if region == "outside" else None,
            costs=stop_costs(d, prices.get(d.destination_id, []), state),
        ))
    trip_costs, meal_cover, prompts = _trip_costs(preview)
    lodging, lodging_note = _lodging(preview)
    inp = TimelineInput(
        stops=stops, legs=_legs(preview, ordered, state, lodging),
        start_date=state.travel_start_date, day_count=state.day_count or 1,
        departure_time=state.departure_time, return_deadline=state.return_deadline,
        pace=state.pace, return_to_origin=state.return_to_origin is True,
        origin_label=state.origin.label if state.origin else "your starting point",
        return_label=state.return_label, traveler_count=state.traveler_count,
        child_ages=list(state.child_ages), total_budget=preview.whole_trip_budget,
        include_meals=data.include_meals, trip_costs=trip_costs, meal_included_in=meal_cover,
        budget_prompts=prompts,
        pins=[Pin(p.destination_id, p.day, p.starts_at) for p in data.pins],
        lodging=lodging, lodging_note=lodging_note,
    )
    timeline = build_timeline(inp)
    if unavailable:
        timeline = _with_unavailable(timeline, unavailable)
    return TimelineResponse(
        input_revision=data.input_revision, timeline=timeline,
        changes=describe_changes(data.previous, timeline) if data.previous else [],
        route_status=preview.route.status, unavailable_destination_ids=unavailable,
    )


def _with_unavailable(timeline: Timeline, unavailable: list[int]) -> Timeline:
    """A pick that is no longer active is reported, never silently dropped."""
    checks = [c for c in timeline.checks if c.id != "selected_places"]
    checks.append(Check(
        id="selected_places", status="failed", destination_ids=unavailable,
        message="Some selected places are no longer available in Lakbay's catalog."))
    return timeline.model_copy(update={"checks": checks, "feasible": False})


# ---- what changed -----------------------------------------------------------------------


def _visits(timeline: Timeline) -> dict[int, tuple[int, str, str]]:
    found = {}
    for day in timeline.days:
        for item in day.items:
            if item.kind == "visit" and item.destination_id is not None:
                found[item.destination_id] = (
                    item.day, item.label, clock_text(item.starts_at) if item.starts_at else "")
    return found


def describe_changes(previous: Timeline, current: Timeline) -> list[str]:
    """Plain sentences for what moved between two timelines of the same trip."""
    before, after = _visits(previous), _visits(current)
    changes: list[str] = []
    for place_id, (day, name, start) in after.items():
        if place_id not in before:
            changes.append(f"{name} was added on day {day} at {start}.")
            continue
        old_day, _, old_start = before[place_id]
        if old_day != day:
            changes.append(f"{name} moved from day {old_day} to day {day}.")
        if old_start != start:
            changes.append(f"{name} now starts at {start}, not {old_start}.")
    changes.extend(f"{name} was removed." for place_id, (_, name, _) in before.items()
                   if place_id not in after)
    old_conflicts = {(c.code, c.destination_id) for c in previous.conflicts}
    new_conflicts = {(c.code, c.destination_id): c for c in current.conflicts}
    changes.extend(f"New problem: {c.message}" for key, c in new_conflicts.items()
                   if key not in old_conflicts)
    changes.extend("A problem from before is resolved."
                   for key in old_conflicts if key not in new_conflicts)
    if previous.feasible != current.feasible:
        changes.append("The itinerary now works." if current.feasible
                       else "The itinerary no longer works.")
    return changes

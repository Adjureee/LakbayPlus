"""Deterministic catalog itinerary planner (no AI required)."""

from __future__ import annotations

from dataclasses import dataclass
from decimal import Decimal
from math import asin, cos, radians, sin, sqrt
import re

from fastapi import status

from app.core.exceptions import LakbayAPIError
from app.features.destinations.models import Destination
from app.features.destinations.region import province_for_destination
from app.features.planning.schemas import (
    CatalogDraftActivity,
    CatalogDraftDay,
    CatalogDraftOption,
    PlanningDraftRequest,
    PlanningDraftResponse,
    PlanningPreviewResponse,
    PlanningState,
)
from app.features.recommendations import scoring
from app.features.recommendations.preference_groups import load_groups
from app.features.routes.schemas import RouteCoordinate, RouteOptimizeRequest, RouteSummaryResponse
from app.features.routes.service import RouteService

SOURCE_LABEL = "Built from Lakbay's catalog, without AI"

_STAY_DURATION_MINUTES: dict[str, int] = {
    "quick_stop": 90,
    "short": 90,
    "half_day": 210,
    "full_day": 420,
    "overnight": 480,
    "multi_day": 480,
}

_STOPWORDS = frozenset({"the", "a", "an", "in", "to", "of", "and", "for", "near", "city", "island", "davao"})


@dataclass(frozen=True)
class _OrderedStop:
    destination: Destination
    leg_distance_km: float
    leg_minutes: int
    needs_ferry: bool


def _haversine_km(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    r = 6371.0
    dlat = radians(lat2 - lat1)
    dlng = radians(lng2 - lng1)
    a = sin(dlat / 2) ** 2 + cos(radians(lat1)) * cos(radians(lat2)) * sin(dlng / 2) ** 2
    return 2 * r * asin(min(1.0, sqrt(a)))


def _tokens(text: str | None) -> list[str]:
    if not text:
        return []
    return [
        tok for tok in re.split(r"[^a-z0-9]+", text.casefold())
        if tok and tok not in _STOPWORDS and len(tok) >= 2
    ]


def _filter_by_place_query(
    destinations: list[Destination],
    *,
    city: str | None,
    query: str | None,
) -> list[Destination]:
    needle = (city or query or "").strip()
    if not needle:
        return destinations
    lower_needle = needle.casefold()
    terms = _tokens(needle)

    exact_geo: list[Destination] = []
    fuzzy_geo: list[Destination] = []
    text_match: list[Destination] = []

    for dest in destinations:
        province = (
            province_for_destination(
                dest.lat,
                dest.lng,
                district=dest.district,
                location=dest.location,
            )
            or ""
        )
        geo_text = " ".join(
            part for part in (dest.district, dest.location, province, dest.island_group) if part
        ).casefold()
        all_text = " ".join(
            part
            for part in (
                geo_text,
                dest.name,
                dest.category,
                dest.vibes,
                dest.activities,
            )
            if part
        ).casefold()

        if lower_needle in geo_text:
            exact_geo.append(dest)
        elif terms and all(term in geo_text for term in terms):
            fuzzy_geo.append(dest)
        elif lower_needle in all_text or (terms and any(term in all_text for term in terms)):
            text_match.append(dest)

    return exact_geo or fuzzy_geo or text_match


def _rank_candidates(
    candidates: list[Destination],
    *,
    state: PlanningState,
) -> list[Destination]:
    groups = load_groups()
    interests = list(state.interests)
    budget_per_person: Decimal | None = None
    travelers = state.traveler_count or 2
    if state.total_budget is not None and state.total_budget > 0:
        if state.budget_scope == "per_person":
            budget_per_person = state.total_budget
        else:
            budget_per_person = state.total_budget / Decimal(max(1, travelers))

    max_min = scoring.max_travel_minutes(state.day_count)
    has_origin = state.origin is not None and state.origin.lat is not None and state.origin.lng is not None
    has_children = bool(state.child_ages)

    scored: list[tuple[float, Destination]] = []
    for dest in candidates:
        matched_groups = 0
        for interest in interests:
            resolved = groups.resolve(interest)
            if resolved is None:
                continue
            member = groups.membership(resolved.group, dest.category, dest.destination_id)
            if member is not None and (
                resolved.subtype is None or resolved.subtype in member.subtypes
            ):
                matched_groups += 1
        matched_text, _ = scoring.interest_matches(
            interests,
            {"category": dest.category, "vibes": dest.vibes, "activities": dest.activities},
        )
        effective_matches = max(len(matched_text), matched_groups)

        est_minutes: float | None = None
        if has_origin:
            km = _haversine_km(
                float(state.origin.lat),
                float(state.origin.lng),
                dest.lat,
                dest.lng,
            )
            est_minutes = (km / 45.0) * 60.0 + (45.0 if dest.island_group else 0.0)

        values = {
            "interest": scoring.interest_score(len(interests), effective_matches),
            "travel": scoring.travel_score(est_minutes, max_min),
            "budget": scoring.budget_score(dest.estimated_cost, budget_per_person),
            "group_fit": scoring.group_fit_score(
                has_children=has_children,
                traveler_count=travelers,
                is_kid_friendly=dest.family_friendly or dest.is_kid_friendly,
                group_friendly=dest.group_friendly,
            ),
            "popularity": scoring.NEUTRAL,
        }
        points = scoring.weighted_points(values, scoring.WEIGHTS)
        scored.append((scoring.total_score(points), dest))

    scored.sort(key=lambda item: (-item[0], item[1].destination_id))
    return [dest for _, dest in scored]


def _nearest_neighbor_order(
    destinations: list[Destination],
    *,
    origin_lat: float | None,
    origin_lng: float | None,
    origin_island: str | None = None,
) -> list[_OrderedStop]:
    if not destinations:
        return []
    remaining = list(destinations)
    ordered: list[_OrderedStop] = []

    if origin_lat is not None and origin_lng is not None:
        cur_lat, cur_lng, cur_island = origin_lat, origin_lng, origin_island
    else:
        first = remaining.pop(0)
        ordered.append(_OrderedStop(first, 0.0, 0, bool(first.island_group)))
        cur_lat, cur_lng, cur_island = first.lat, first.lng, first.island_group

    while remaining:
        next_idx = min(
            range(len(remaining)),
            key=lambda i: _haversine_km(cur_lat, cur_lng, remaining[i].lat, remaining[i].lng),
        )
        pick = remaining.pop(next_idx)
        km = _haversine_km(cur_lat, cur_lng, pick.lat, pick.lng)
        needs_ferry = (pick.island_group or None) != (cur_island or None)
        minutes = max(15, round((km / 45.0) * 60.0 + 10.0 + (45.0 if needs_ferry else 0.0)))
        ordered.append(_OrderedStop(pick, round(km, 2), minutes, needs_ferry))
        cur_lat, cur_lng, cur_island = pick.lat, pick.lng, pick.island_group

    return ordered


def _stops_from_route_summary(
    destinations_by_id: dict[int, Destination],
    summary: RouteSummaryResponse,
) -> list[_OrderedStop]:
    leg_by_target = {
        leg.to_destination_id: leg
        for leg in summary.legs
        if leg.to_destination_id is not None
    }
    ordered: list[_OrderedStop] = []
    seen: set[int] = set()
    for stop in summary.stops:
        if stop.destination_id is None or stop.destination_id in seen:
            continue
        dest = destinations_by_id.get(stop.destination_id)
        if dest is None:
            continue
        seen.add(dest.destination_id)
        leg = leg_by_target.get(dest.destination_id)
        ordered.append(
            _OrderedStop(
                destination=dest,
                leg_distance_km=float(leg.distance_km) if leg else 0.0,
                leg_minutes=leg.duration_minutes if leg else 0,
                needs_ferry=bool(leg.sea_crossings) if leg else bool(dest.island_group),
            )
        )
    for dest_id, dest in destinations_by_id.items():
        if dest_id not in seen:
            ordered.append(_OrderedStop(dest, 0.0, 20, bool(dest.island_group)))
    return ordered


def _format_clock(start_minutes: int) -> str:
    h = (start_minutes // 60) % 24
    m = start_minutes % 60
    return f"{h:02d}:{m:02d}"


def _visit_minutes(dest: Destination, *, pace_multiplier: float) -> int:
    key = (dest.stay_duration_type or "half_day").strip().lower()
    base = _STAY_DURATION_MINUTES.get(key, 180)
    return min(480, max(60, round(base * pace_multiplier)))


def _build_option(
    *,
    option_number: int,
    title: str,
    summary: str,
    ordered_stops: list[_OrderedStop],
    day_count: int,
    start_hour_minutes: int,
    daily_budget_minutes: int,
    pace_multiplier: float,
    preview: PlanningPreviewResponse,
    route_source: str,
) -> CatalogDraftOption:
    buckets: list[list[CatalogDraftActivity]] = [[] for _ in range(day_count)]
    day_elapsed = [0 for _ in range(day_count)]
    day_titles: list[list[str]] = [[] for _ in range(day_count)]

    current_day = 0
    for idx, stop in enumerate(ordered_stops):
        dest = stop.destination
        visit_mins = _visit_minutes(dest, pace_multiplier=pace_multiplier)
        travel_mins = stop.leg_minutes
        needed = travel_mins + visit_mins

        if (
            buckets[current_day]
            and day_elapsed[current_day] + needed > daily_budget_minutes
            and current_day < day_count - 1
        ):
            current_day += 1

        clock = start_hour_minutes + day_elapsed[current_day]
        if travel_mins > 0 and idx > 0:
            clock += min(travel_mins, 90)
        clock_str = _format_clock(min(clock, 18 * 60))

        price_listed = dest.estimated_cost is not None
        cost = (
            Decimal(dest.estimated_cost).quantize(Decimal("0.01"))
            if price_listed
            else Decimal("0.00")
        )
        cost_source = "catalog_estimate" if price_listed else "catalog_unlisted"

        note_parts: list[str] = []
        if not price_listed:
            note_parts.append("Price not listed in Lakbay catalog.")
        elif dest.entrance_fee:
            note_parts.append(f"Listed fee info: {dest.entrance_fee}.")
        if stop.needs_ferry:
            note_parts.append("Boat/ferry crossing required; check pier schedule.")
        if dest.operating_hours:
            note_parts.append(f"Listed hours: {dest.operating_hours}.")
        if dest.estimated_travel_time:
            note_parts.append(f"Travel reference: {dest.estimated_travel_time}.")

        desc = (dest.description or f"Visit {dest.name} in {dest.location or dest.district or 'Davao Region'}.").strip()
        if len(desc) > 180:
            desc = desc[:177].rstrip() + "..."

        buckets[current_day].append(
            CatalogDraftActivity(
                time=clock_str,
                title=f"Visit {dest.name}",
                description=desc,
                destination_id=dest.destination_id,
                estimated_cost=cost,
                cost_listed=price_listed,
                cost_source=cost_source,
                notes=" ".join(note_parts) if note_parts else None,
            )
        )
        day_titles[current_day].append(dest.name)
        day_elapsed[current_day] += needed

    # Add explicitly selected accommodation or transport rates on Day 1 without inventing costs.
    for acc in preview.accommodation_options:
        if not acc.selected:
            continue
        listed = acc.listed_price is not None
        buckets[0].append(
            CatalogDraftActivity(
                time="17:30",
                title=f"Stay: {acc.name}",
                description=f"{acc.room_type} stay in catalog.",
                destination_id=acc.destination_id,
                accommodation_id=acc.accommodation_id,
                estimated_cost=(
                    Decimal(acc.listed_price).quantize(Decimal("0.01"))
                    if listed
                    else Decimal("0.00")
                ),
                cost_listed=listed,
                cost_source="catalog_verified" if listed and acc.price_basis else (
                    "catalog_estimate" if listed else "catalog_unlisted"
                ),
                notes=(
                    None if listed else "Price not listed in Lakbay catalog."
                ),
            )
        )

    for tr in preview.transport_options:
        if not tr.selected or tr.transportation_id is None:
            continue
        listed = tr.listed_price is not None
        buckets[0].append(
            CatalogDraftActivity(
                time="08:00",
                title=tr.label,
                description=f"{tr.vehicle_type} transfer from Lakbay catalog.",
                destination_id=tr.destination_id,
                transportation_id=tr.transportation_id,
                estimated_cost=(
                    Decimal(tr.listed_price).quantize(Decimal("0.01"))
                    if listed
                    else Decimal("0.00")
                ),
                cost_listed=listed,
                cost_source="catalog_verified" if listed and tr.price_basis else (
                    "catalog_estimate" if listed else "catalog_unlisted"
                ),
                notes=(
                    None if listed else "Fare not listed in Lakbay catalog."
                ),
            )
        )

    anchor_dest = ordered_stops[-1].destination
    built_days: list[CatalogDraftDay] = []
    for day_idx in range(day_count):
        acts = buckets[day_idx]
        places = day_titles[day_idx]
        if not acts:
            acts = [
                CatalogDraftActivity(
                    time="09:30",
                    title=f"Explore more around {anchor_dest.name}",
                    description=f"Unhurried follow-up time or return transit from {anchor_dest.location or anchor_dest.district or anchor_dest.name}.",
                    destination_id=anchor_dest.destination_id,
                    estimated_cost=Decimal("0.00"),
                    cost_listed=True,
                    cost_source="catalog_unlisted",
                    notes="Flexible pace buffer; no extra listed charge.",
                )
            ]
            places = [anchor_dest.name]
        day_num = day_idx + 1
        built_days.append(
            CatalogDraftDay(
                day=day_num,
                title=f"Day {day_num}: {', '.join(places[:2])}",
                summary=f"Covers {', '.join(places)} ordered along your route.",
                activities=acts,
            )
        )

    total_cost = sum(
        (act.estimated_cost for day in built_days for act in day.activities),
        Decimal("0.00"),
    ).quantize(Decimal("0.01"))
    is_over_budget = (
        preview.whole_trip_budget is not None
        and total_cost > preview.whole_trip_budget
    )
    warnings = [
        f"{SOURCE_LABEL}. Verify opening hours, transport schedules, and unlisted fees before traveling.",
        f"Route order computed via {route_source}.",
    ]
    return CatalogDraftOption(
        option_number=option_number,
        title=title,
        summary=summary,
        estimated_total_cost=total_cost,
        is_over_budget=is_over_budget,
        days=built_days,
        quality_warnings=warnings,
    )


async def build_catalog_draft(
    *,
    data: PlanningDraftRequest,
    destinations_repo,
    route_service: RouteService | None,
    preview_fn,
) -> PlanningDraftResponse:
    """Build a deterministic catalog itinerary option set without calling any AI model."""
    state = data.state
    if state.destination_ids:
        active = await destinations_repo.list_active_destinations(state.destination_ids)
        by_id = {d.destination_id: d for d in active}
        selected = [by_id[i] for i in state.destination_ids if i in by_id]
    else:
        all_active = await destinations_repo.list_all_active_destinations()
        filtered = _filter_by_place_query(all_active, city=data.city, query=data.query)
        ranked = _rank_candidates(filtered, state=state)
        target_count = min(data.max_places, max(2, (state.day_count or 2) * 2))
        selected = ranked[:target_count]

    if not selected:
        raise LakbayAPIError(
            "No active Lakbay catalog places matched that request.",
            code="planning_draft_no_places",
            status_code=status.HTTP_404_NOT_FOUND,
        )

    day_count = state.day_count or min(3, max(1, (len(selected) + 1) // 2))
    traveler_count = state.traveler_count or 2
    effective_state = state.model_copy(
        update={
            "destination_ids": [d.destination_id for d in selected],
            "day_count": day_count,
            "traveler_count": traveler_count,
            "night_count": (
                state.night_count if state.night_count is not None else max(0, day_count - 1)
            ),
            "return_to_origin": (
                state.return_to_origin if state.return_to_origin is not None else False
            ),
        }
    )

    from app.features.planning.schemas import PlanningPreviewRequest

    preview = await preview_fn(
        PlanningPreviewRequest(input_revision=data.input_revision, state=effective_state)
    )

    destinations_by_id = {d.destination_id: d for d in selected}
    route_source = "catalog_coordinates"
    ordered_stops: list[_OrderedStop] | None = None

    has_origin_coords = (
        effective_state.origin is not None
        and effective_state.origin.lat is not None
        and effective_state.origin.lng is not None
    )
    if route_service is not None and (len(selected) >= 2 or has_origin_coords):
        try:
            origin_coord = (
                RouteCoordinate(
                    label=effective_state.origin.label,
                    lat=float(effective_state.origin.lat),
                    lng=float(effective_state.origin.lng),
                )
                if has_origin_coords
                else None
            )
            summary = await route_service.optimize_route(
                RouteOptimizeRequest(
                    destination_ids=[d.destination_id for d in selected],
                    origin=origin_coord,
                    return_to_origin=bool(has_origin_coords and effective_state.return_to_origin),
                    preserve_first_destination=True,
                )
            )
            ordered_stops = _stops_from_route_summary(destinations_by_id, summary)
            route_source = summary.route_provider
        except Exception:
            ordered_stops = None

    if ordered_stops is None:
        ordered_stops = _nearest_neighbor_order(
            selected,
            origin_lat=effective_state.origin.lat if has_origin_coords else None,
            origin_lng=effective_state.origin.lng if has_origin_coords else None,
        )

    area_label = (
        data.city
        or ordered_stops[0].destination.district
        or "Davao Region"
    )
    options: list[CatalogDraftOption] = [
        _build_option(
            option_number=1,
            title=f"{area_label} Balanced Catalog Route",
            summary=f"{SOURCE_LABEL}. Balanced {day_count}-day pace along the shortest stop order.",
            ordered_stops=ordered_stops,
            day_count=day_count,
            start_hour_minutes=8 * 60 + 30,
            daily_budget_minutes=540,
            pace_multiplier=1.0,
            preview=preview,
            route_source=route_source,
        )
    ]
    if data.option_count >= 2:
        options.append(
            _build_option(
                option_number=2,
                title=f"{area_label} Relaxed Pace Route",
                summary=f"{SOURCE_LABEL}. Later 09:30 start with longer stop buffers.",
                ordered_stops=ordered_stops,
                day_count=day_count,
                start_hour_minutes=9 * 60 + 30,
                daily_budget_minutes=450,
                pace_multiplier=1.2,
                preview=preview,
                route_source=route_source,
            )
        )

    unlisted_ids = [
        stop.destination.destination_id
        for stop in ordered_stops
        if stop.destination.estimated_cost is None
    ]
    return PlanningDraftResponse(
        source="catalog_deterministic",
        source_label=SOURCE_LABEL,
        options=options,
        planning_preview=preview,
        unlisted_cost_destination_ids=unlisted_ids,
        route_source=route_source,
    )

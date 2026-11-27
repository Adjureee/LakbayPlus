"""Read-only Phase 15B and Phase 3 inputs for selected itinerary destinations."""

from dataclasses import dataclass

from fastapi import status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.exceptions import LakbayAPIError
from app.features.destinations.models import Destination
from app.features.geo_analytics.dependencies import get_geo_group_limiter
from app.features.geo_analytics.schemas import DestinationGroupsRequest, DestinationGroupsResponse
from app.features.geo_analytics.service import GeoAnalyticsService
from app.features.planning.schemas import PlanningPreviewResponse
from app.features.recommendations.repository import RecommendationRepository
from app.features.recommendations.schemas import RecommendationItem, RecommendationRequest
from app.features.recommendations.service import RecommendationService
from app.features.routes.day_planner import (
    StopPlanInput,
    normalize_island_group,
    plan_multi_day_route,
)
from app.features.routes.sea_planner import (
    PlannerPoint,
    SeaNetwork,
    haversine_km,
    road_minutes,
)
from app.features.routes.service import RouteService
from app.features.users.models import User


@dataclass(frozen=True)
class GeographicItineraryPlan:
    """Deterministic island-aware route order & day clustering for AI generation."""

    ordered_destination_ids: tuple[int, ...]
    suggested_day_clusters: list[dict]
    consecutive_legs: list[dict]
    destination_coords: dict[int, tuple[float, float]]
    destination_island_groups: dict[int, str]


def compute_geographic_itinerary_plan(
    *,
    destinations: list[Destination],
    day_count: int,
    origin: PlannerPoint | None = None,
    network: SeaNetwork | None = None,
    travel_mode: str = "driving",
) -> GeographicItineraryPlan:
    """Cluster destinations by geography/island group and compute realistic transit legs."""
    destination_coords: dict[int, tuple[float, float]] = {}
    destination_island_groups: dict[int, str] = {}
    stops: list[StopPlanInput] = []

    for dest in destinations:
        destination_coords[dest.destination_id] = (float(dest.lat), float(dest.lng))
        island = normalize_island_group(getattr(dest, "island_group", None))
        destination_island_groups[dest.destination_id] = island
        stops.append(
            StopPlanInput(
                destination_id=dest.destination_id,
                name=dest.name,
                lat=float(dest.lat),
                lng=float(dest.lng),
                island_group=getattr(dest, "island_group", None),
                stay_duration_type=getattr(dest, "stay_duration_type", None) or "half_day",
                must_visit=True,
            )
        )

    if not stops:
        return GeographicItineraryPlan(
            ordered_destination_ids=(),
            suggested_day_clusters=[],
            consecutive_legs=[],
            destination_coords=destination_coords,
            destination_island_groups=destination_island_groups,
        )

    plan = plan_multi_day_route(
        stops=stops,
        days=max(1, min(14, day_count)),
        pace="balanced",
        origin=origin,
        driving=(travel_mode == "driving"),
        network=network,
    )
    ordered_ids = tuple(
        s.destination_id for s in plan.ordered_stops if s.destination_id is not None
    )

    suggested_day_clusters: list[dict] = []
    for day in plan.days:
        day_ids = [s.destination_id for s in day.stops if s.destination_id is not None]
        day_islands = {
            destination_island_groups[did]
            for did in day_ids
            if did in destination_island_groups
        }
        suggested_day_clusters.append(
            {
                "day": day.day_number,
                "destination_ids": day_ids,
                "destination_names": [s.name for s in day.stops],
                "estimated_transit_hours": round(day.transit_hours, 2),
                "requires_ferry": len(day_islands) > 1 or any(
                    island != "mainland" for island in day_islands
                ),
                **({"continuation_of": day.continuation_of_name} if day.is_continuation_day else {}),
            }
        )

    consecutive_legs: list[dict] = []
    sea_net = network if network is not None else SeaNetwork([], [])
    for a, b in zip(plan.ordered_stops, plan.ordered_stops[1:]):
        group_a = normalize_island_group(a.island_group)
        group_b = normalize_island_group(b.island_group)
        requires_ferry = group_a != group_b
        dist_km = round(haversine_km(a.point, b.point), 1)
        est_minutes = round(road_minutes(a.point, b.point))
        if requires_ferry and not sea_net.is_empty:
            sea_path = sea_net.find_path(a.point, b.point, driving=(travel_mode == "driving"))
            if sea_path is not None:
                est_minutes = round(sea_path.cost_minutes)
        consecutive_legs.append(
            {
                "from_destination_id": a.destination_id,
                "to_destination_id": b.destination_id,
                "distance_km": dist_km,
                "estimated_minutes": est_minutes,
                "requires_ferry": requires_ferry,
            }
        )

    return GeographicItineraryPlan(
        ordered_destination_ids=ordered_ids,
        suggested_day_clusters=suggested_day_clusters,
        consecutive_legs=consecutive_legs,
        destination_coords=destination_coords,
        destination_island_groups=destination_island_groups,
    )


async def selected_geo_inputs(
    *,
    session: AsyncSession,
    user: User | None,
    preview: PlanningPreviewResponse,
    destinations: list[Destination],
    routes: RouteService | None,
    interests: list[str],
) -> tuple[list[RecommendationItem], DestinationGroupsResponse | None]:
    """Rank only allowed IDs and score groups when a planning route was requested."""
    interests = interests or preview.state.interests
    recommendations: list[RecommendationItem] = []
    if interests:
        scorer = RecommendationService(session)
        popularity = await RecommendationRepository(session).list_popularity()
        preference = RecommendationRequest(
            preferred_categories=interests,
            preferred_vibes=interests,
            preferred_activities=interests,
            group_friendly=True if (preview.state.traveler_count or 0) > 1 else None,
        )
        for destination in destinations:
            scored = scorer.score_destination(
                destination=destination,
                preference=preference,
                popularity=popularity.get(destination.destination_id),
            )
            if scored is not None and {"category", "vibes", "activities"}.intersection(scored.matched_fields):
                recommendations.append(scored)
        recommendations.sort(key=lambda item: (-item.score, item.destination_id))
        recommendations = recommendations[:5]

    route = preview.route
    if (
        user is None
        or routes is None
        or route.summary is None
        or route.travel_mode is None
        or len(preview.state.destination_ids) < 2
    ):
        return recommendations, None

    group_size = min(3, len(preview.state.destination_ids), get_settings().route_max_destinations)
    if group_size < 2:
        return recommendations, None
    get_geo_group_limiter().check(user.user_id)
    try:
        groups = await GeoAnalyticsService(session, routes).group(
            data=DestinationGroupsRequest(
                destination_ids=preview.state.destination_ids,
                travel_mode=route.travel_mode,
                group_size=group_size,
                max_groups=3,
                max_destination_cost=preview.whole_trip_budget,
                max_route_minutes=min(1440, 240 * (preview.state.day_count or 1)),
            ),
            user=user,
        )
    except LakbayAPIError as exc:
        if exc.status_code == status.HTTP_429_TOO_MANY_REQUESTS:
            raise
        # A group is supplementary context; the authoritative preview remains valid.
        groups = DestinationGroupsResponse(
            groups=[], candidates_considered=0,
            warnings=[f"Phase 15B grouping unavailable: {exc.message}"],
        )
    return recommendations, groups

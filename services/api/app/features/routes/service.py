import logging
from dataclasses import dataclass
from decimal import Decimal
from math import asin, cos, radians, sin, sqrt
from typing import Literal

from fastapi import status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.exceptions import LakbayAPIError
from app.features.destinations.models import Destination
from app.features.routes.ordering import (
    EXACT_ORDER_MAX_STOPS,
    exact_order,
    nearest_neighbor_two_opt,
)
from app.features.routes.multimodal import (
    build_multimodal_response,
    network_from_links,
    planner_point,
    spans_island_groups,
)
from app.features.routes.polyline import decode_polyline5, join_polylines5
from app.features.routes.repository import RouteRepository
from app.features.routes.snap_policy import (
    build_road_run_segments,
    snap_limits,
)
from app.features.sea_links.repository import SeaLinkRepository
from app.features.routes.schemas import (
    OrderMethod,
    RouteCoordinate,
    RouteDirectionStep,
    RouteFerryCrossing,
    RouteLeg,
    RouteOptimizeRequest,
    RoutePreviewRequest,
    RouteSegment,
    RouteStop,
    RouteSummaryResponse,
    RouteTrafficSummary,
    TrafficLevel,
    TravelMode,
)
from app.integrations.google_routes.client import GoogleRoutesClient
from app.integrations.google_routes.errors import GoogleRoutesClientError
from app.integrations.google_routes.schemas import GoogleRouteLeg, GoogleRouteResult
from app.integrations.osrm.client import OSRMClient
from app.integrations.osrm.errors import OSRMClientError
from app.integrations.osrm.schemas import (
    OSRMFerryCrossing,
    OSRMLeg,
    OSRMRouteResult,
    OSRMStep,
)

EARTH_RADIUS_KM = 6371.0
ZERO_DISTANCE = Decimal("0.00")
FALLBACK_SPEED_KMH = {
    "driving": Decimal("40"),
    "walking": Decimal("5"),
    "cycling": Decimal("15"),
    "public_transport": Decimal("30"),
}

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class RoutePlanStop:
    destination_id: int | None
    name: str
    lat: float
    lng: float
    is_origin: bool = False
    coordinate_basis: Literal["origin", "verified_arrival", "attraction"] = "attraction"
    # None means the mainland; see app.features.sea_links.
    island_group: str | None = None
    is_port: bool = False
    access_trail_polyline: str | None = None

    @property
    def coordinate(self) -> RouteCoordinate:
        return RouteCoordinate(label=self.name, lat=self.lat, lng=self.lng)


class RouteService:
    def __init__(
        self,
        session: AsyncSession,
        osrm_client: OSRMClient,
        google_routes_client: GoogleRoutesClient | None = None,
    ) -> None:
        self.routes = RouteRepository(session)
        self.sea_links = SeaLinkRepository(session)
        self.osrm_client = osrm_client
        self.google_routes_client = google_routes_client

    async def preview_route(
        self,
        data: RoutePreviewRequest,
    ) -> RouteSummaryResponse:
        stops = await self._build_stops(data)
        return await self._preview_stops(data, stops)

    async def _preview_stops(
        self,
        data: RoutePreviewRequest | RouteOptimizeRequest,
        stops: list[RoutePlanStop],
    ) -> RouteSummaryResponse:
        route_stops = _append_return_stop(stops, data.return_to_origin)

        if spans_island_groups(route_stops):
            return await self._multimodal_route(data, route_stops)

        if data.travel_mode == "public_transport":
            return _estimated_response(
                travel_mode=data.travel_mode,
                stops=route_stops,
                route_provider="stored_transportation_estimate",
                warnings=[
                    "Public transit times are estimates. For fares, see the "
                    "transport rates listed for the place.",
                ],
            )

        if len(route_stops) <= 1:
            return _empty_route_response(
                travel_mode=data.travel_mode,
                stops=route_stops,
                route_provider="none",
                is_estimated=False,
            )

        traffic_response, live_traffic_warning = await self._try_live_traffic(
            data, route_stops,
        )
        if traffic_response is not None:
            return traffic_response

        warnings = [live_traffic_warning] if live_traffic_warning else []

        try:
            osrm_result = await self._road_preview(data.travel_mode, route_stops)

            return _osrm_response(
                travel_mode=data.travel_mode,
                stops=route_stops,
                osrm_result=osrm_result,
                warnings=warnings,
            )
        except (OSRMClientError, ValueError) as exc:
            if data.travel_mode == "driving":
                logger.warning("Driving OSRM route lookup failed: %s", exc)
            warnings.append("OSRM was unavailable, so Haversine estimates were used.")

            return _estimated_response(
                travel_mode=data.travel_mode,
                stops=route_stops,
                route_provider="haversine",
                warnings=warnings,
            )

    async def optimize_route(
        self,
        data: RouteOptimizeRequest,
    ) -> RouteSummaryResponse:
        stops = await self._build_stops(data)

        preserve_first = data.origin is not None or data.preserve_first_destination

        if spans_island_groups(stops):
            return await self._island_aware_optimize(
                data, stops, preserve_first=preserve_first,
            )

        if data.travel_mode == "public_transport":
            ordered_stops = _heuristic_order(
                stops, preserve_first=preserve_first, roundtrip=data.return_to_origin,
            )
            route_stops = _append_return_stop(ordered_stops, data.return_to_origin)

            return _with_order_method(_estimated_response(
                travel_mode=data.travel_mode,
                stops=route_stops,
                route_provider="stored_transportation_estimate",
                warnings=[
                    "Public transit stop order is estimated from the places' "
                    "locations.",
                ],
            ), "nearest_neighbor_2opt")

        if len(stops) <= 1:
            return _empty_route_response(
                travel_mode=data.travel_mode,
                stops=stops,
                route_provider="none",
                is_estimated=False,
            )

        # A fixed origin and one destination have no visit order to optimize.
        # OSRM Route also checks whether both coordinates snap near the road.
        if data.origin is not None and len(data.destination_ids) == 1:
            return await self._preview_stops(data, stops)

        # Small routes compare every possible order with OSRM travel times; larger
        # ones, or a failed exact attempt, use OSRM Trip, then nearest neighbor.
        if len(stops) <= EXACT_ORDER_MAX_STOPS:
            exact_response = await self._exact_order_route(
                data, stops, preserve_first=preserve_first,
            )
            if exact_response is not None:
                return exact_response

        order_warning = (
            "OSRM Trip returns a suggested route order; it is not "
            "guaranteed to be mathematically optimal."
        )

        try:
            osrm_result = await self.osrm_client.optimize_route(
                travel_mode=data.travel_mode,
                coordinates=[stop.coordinate for stop in stops],
                roundtrip=data.return_to_origin,
                preserve_first=preserve_first,
            )
            ordered_stops = _apply_stop_order(
                stops, osrm_result.stop_order, preserve_first=preserve_first,
            )
            route_stops = _append_return_stop(ordered_stops, data.return_to_origin)
            osrm_response = _osrm_response(
                travel_mode=data.travel_mode,
                stops=route_stops,
                osrm_result=osrm_result,
                warnings=[order_warning],
            )
        except (OSRMClientError, ValueError) as exc:
            if data.travel_mode == "driving":
                logger.warning("Driving OSRM trip lookup failed: %s", exc)
            ordered_stops = _heuristic_order(
                stops, preserve_first=preserve_first, roundtrip=data.return_to_origin,
            )
            route_stops = _append_return_stop(ordered_stops, data.return_to_origin)

            traffic_response, live_traffic_warning = await self._try_live_traffic(
                data,
                route_stops,
                success_warnings=[
                    "OSRM optimization was unavailable, so Haversine "
                    "nearest-neighbor ordering with 2-opt was used before adding "
                    "live traffic ETA.",
                ],
            )
            if traffic_response is not None:
                return _with_order_method(traffic_response, "nearest_neighbor_2opt")

            warnings = [live_traffic_warning] if live_traffic_warning else []
            warnings.append(
                "OSRM optimization was unavailable, so a Haversine "
                "nearest-neighbor estimate with 2-opt was used."
            )

            return _with_order_method(_estimated_response(
                travel_mode=data.travel_mode,
                stops=route_stops,
                route_provider="haversine",
                warnings=warnings,
            ), "nearest_neighbor_2opt")

        traffic_response, live_traffic_warning = await self._try_live_traffic(
            data,
            route_stops,
            success_warnings=[
                order_warning,
                "OSRM was used to suggest destination order; "
                "Google Routes added live traffic ETA.",
            ],
        )
        if traffic_response is not None:
            return _with_order_method(traffic_response, "osrm_trip")
        if live_traffic_warning:
            osrm_response.warnings.insert(0, live_traffic_warning)
        return _with_order_method(osrm_response, "osrm_trip")

    async def plan_route(self, data) -> "RoutePlanResponse":
        """Optimize visit order, partition multi-place days, and build geometry."""
        from app.features.routes.day_planner import (
            StopPlanInput,
            normalize_island_group,
            plan_multi_day_route,
        )
        from app.features.routes.schemas import (
            RouteCoordinate,
            RoutePlanDay,
            RoutePlanResponse,
            RoutePlanSavings,
            RoutePlanStopSummary,
            RoutePreviewRequest,
        )
        from app.features.routes.sea_planner import PlannerPoint

        stops = await self._build_stops(data)
        destinations = await self.routes.list_active_destinations_by_ids(
            list(data.destination_ids),
        )
        stay_by_id = {
            dest.destination_id: dest.stay_duration_type for dest in destinations
        }

        origin_stop = stops[0] if stops and stops[0].is_origin else None
        dest_stops = [stop for stop in stops if not stop.is_origin]
        must_set = (
            set(data.must_visit_destination_ids)
            if data.must_visit_destination_ids is not None
            else None
        )

        plan_inputs = [
            StopPlanInput(
                destination_id=stop.destination_id,
                name=stop.name,
                lat=stop.lat,
                lng=stop.lng,
                island_group=stop.island_group,
                stay_duration_type=stay_by_id.get(stop.destination_id, "half_day"),
                must_visit=True if must_set is None else (stop.destination_id in must_set),
            )
            for stop in dest_stops
        ]

        override_by_pair: dict[tuple[int | None, int | None], tuple[float, float]] = {}
        matrix_provider = getattr(self.osrm_client, "provider_name", "osrm")

        if data.travel_mode in ("driving", "walking", "cycling") and self.osrm_client is not None:
            grouped: dict[str, list[tuple[int | None, RouteCoordinate]]] = {}
            if origin_stop is not None:
                grouped.setdefault(
                    normalize_island_group(origin_stop.island_group),
                    [],
                ).append((None, origin_stop.coordinate))
            for s in plan_inputs:
                grouped.setdefault(s.normalized_island, []).append(
                    (
                        s.destination_id,
                        RouteCoordinate(
                            label=s.name,
                            lat=s.lat,
                            lng=s.lng,
                            island_group=s.island_group,
                        ),
                    )
                )

            for island, entries in grouped.items():
                if len(entries) < 2:
                    continue
                try:
                    matrix_res = await self.osrm_client.matrix(
                        travel_mode=data.travel_mode,
                        coordinates=[coord for _, coord in entries],
                    )
                    for i, (key_a, _) in enumerate(entries):
                        for j, (key_b, _) in enumerate(entries):
                            if i == j:
                                continue
                            dur_s = matrix_res.durations_seconds[i][j]
                            dist_m = matrix_res.distances_meters[i][j]
                            if dur_s is not None and dur_s > 0:
                                mins = dur_s / 60.0
                                km = (dist_m / 1000.0) if dist_m is not None else 0.0
                                override_by_pair[(key_a, key_b)] = (mins, max(0.0, km))
                except (OSRMClientError, ValueError) as exc:
                    logger.info("Matrix lookup skipped for %s: %s", island, exc)

        network = await self._sea_network()
        origin_pt = (
            PlannerPoint(origin_stop.lat, origin_stop.lng, origin_stop.island_group)
            if origin_stop is not None
            else None
        )
        plan = plan_multi_day_route(
            stops=plan_inputs,
            days=data.days,
            pace=data.pace,
            origin=origin_pt,
            roundtrip=data.return_to_origin,
            locked_first_destination_id=data.locked_first_destination_id,
            preserve_first_destination=data.preserve_first_destination,
            driving=data.travel_mode == "driving",
            prune_optional_to_fit=data.prune_optional_to_fit,
            network=network,
            override_by_pair=override_by_pair or None,
            cost_source=matrix_provider,
        )

        ordered_ids = [
            s.destination_id for s in plan.ordered_stops if s.destination_id is not None
        ]
        preview_req = RoutePreviewRequest(
            destination_ids=ordered_ids or list(data.destination_ids[:1]),
            travel_mode=data.travel_mode,
            origin=data.origin,
            return_to_origin=data.return_to_origin,
            use_live_traffic=data.use_live_traffic,
        )
        route_summary = await self.preview_route(preview_req)
        route_summary = _with_order_method(route_summary, plan.order_method)

        merged_warnings = list(plan.warnings)
        for w in route_summary.warnings:
            if w not in merged_warnings:
                merged_warnings.append(w)

        cost_source = plan.cost_source
        if cost_source not in ("haversine", "osrm", "mapbox", "google_routes"):
            cost_source = "haversine"

        return RoutePlanResponse(
            order_method=plan.order_method,
            cost_source=cost_source,
            suggested_days=plan.suggested_days,
            pace=data.pace,
            savings_vs_input=RoutePlanSavings(
                baseline_distance_km=plan.savings_vs_input.baseline_distance_km,
                optimized_distance_km=plan.savings_vs_input.optimized_distance_km,
                distance_saved_km=plan.savings_vs_input.distance_saved_km,
                distance_saved_percent=plan.savings_vs_input.distance_saved_percent,
                baseline_transit_minutes=plan.savings_vs_input.baseline_transit_minutes,
                optimized_transit_minutes=plan.savings_vs_input.optimized_transit_minutes,
                minutes_saved=plan.savings_vs_input.minutes_saved,
            ),
            warnings=merged_warnings,
            skipped_destination_ids=[
                s.destination_id for s in plan.skipped_stops if s.destination_id is not None
            ],
            days=[
                RoutePlanDay(
                    day_number=day.day_number,
                    stops=[
                        RoutePlanStopSummary(
                            destination_id=s.destination_id,
                            name=s.name,
                            lat=s.lat,
                            lng=s.lng,
                            island_group=s.island_group,
                            stay_duration_type=s.normalized_stay_type,
                            visit_hours=s.visit_hours,
                        )
                        for s in day.stops
                    ],
                    visit_hours=round(day.visit_hours, 2),
                    transit_hours=round(day.transit_hours, 2),
                    total_hours=round(day.total_hours, 2),
                    is_continuation_day=day.is_continuation_day,
                    continuation_of_name=day.continuation_of_name,
                    is_overloaded=day.is_overloaded,
                    overload_warning=day.overload_warning,
                )
                for day in plan.days
            ],
            route=route_summary,
        )

    async def _sea_network(self):
        return network_from_links(await self.sea_links.list_active_links())

    async def _multimodal_route(
        self,
        data: RoutePreviewRequest | RouteOptimizeRequest,
        route_stops: list[RoutePlanStop],
        *,
        network=None,
    ) -> RouteSummaryResponse:
        """Drive to a pier, cross by boat, drive on; roads never cross water."""
        network = network if network is not None else await self._sea_network()
        warnings = []
        if data.use_live_traffic:
            warnings.append(
                "Live traffic is not applied to routes with boat crossings."
            )
        verified = _arrival_points_verified(route_stops)
        return await build_multimodal_response(
            road_client=self.osrm_client,
            travel_mode=data.travel_mode,
            stops=route_stops,
            network=network,
            port_stop_factory=_port_stop,
            base_warnings=warnings,
            estimated_leg_factory=lambda mode, start, end: _estimated_legs(
                travel_mode=mode, stops=[start, end],
            )[0],
            road_leg_factory=lambda start, end, leg: _route_leg_from_osrm(
                order=1, start=start, end=end, leg=leg, show_steps=verified,
            ),
            estimated_response_factory=lambda stops, extra: _estimated_response(
                travel_mode=data.travel_mode,
                stops=stops,
                route_provider="haversine",
                warnings=extra,
            ),
        )

    async def _island_aware_optimize(
        self,
        data: RouteOptimizeRequest,
        stops: list[RoutePlanStop],
        *,
        preserve_first: bool,
    ) -> RouteSummaryResponse:
        """Order stops so each island is visited in one go, then route via piers."""
        network = await self._sea_network()
        costs = network.order_costs(
            [planner_point(stop) for stop in stops],
            driving=data.travel_mode == "driving",
        )
        if len(stops) <= EXACT_ORDER_MAX_STOPS:
            order = exact_order(
                costs, fixed_start=preserve_first, roundtrip=data.return_to_origin,
            )
        else:
            order = nearest_neighbor_two_opt(
                costs, fixed_start=preserve_first, roundtrip=data.return_to_origin,
            )
        route_stops = _append_return_stop(
            [stops[index] for index in order], data.return_to_origin,
        )
        response = await self._multimodal_route(data, route_stops, network=network)
        response.warnings.insert(
            0,
            "Stops are ordered to keep each island's stops together and limit boat "
            "crossings, using straight-line estimates for the road parts.",
        )
        return _with_order_method(response, "island_aware")

    async def _exact_order_route(
        self,
        data: RouteOptimizeRequest,
        stops: list[RoutePlanStop],
        *,
        preserve_first: bool,
    ) -> RouteSummaryResponse | None:
        """Order by the lowest total OSRM travel time, or None to use OSRM Trip."""
        try:
            matrix = await self.osrm_client.matrix(
                travel_mode=data.travel_mode,
                coordinates=[stop.coordinate for stop in stops],
            )
        except (OSRMClientError, ValueError) as exc:
            logger.info("OSRM table for exact stop ordering failed: %s", exc)
            return None
        durations = matrix.durations_seconds
        if any(value is None for row in durations for value in row):
            # A pair without a road connection cannot be compared fairly.
            return None

        order = exact_order(
            durations, fixed_start=preserve_first, roundtrip=data.return_to_origin,
        )
        route_stops = _append_return_stop(
            [stops[index] for index in order], data.return_to_origin,
        )
        order_warning = (
            "Stops are in the order with the shortest total travel time, found by "
            "comparing every possible order with OSRM travel times."
        )
        try:
            osrm_result = await self._road_preview(data.travel_mode, route_stops)
            osrm_response = _osrm_response(
                travel_mode=data.travel_mode,
                stops=route_stops,
                osrm_result=osrm_result,
                warnings=[order_warning],
            )
        except (OSRMClientError, ValueError) as exc:
            logger.info("OSRM route for the exact stop order failed: %s", exc)
            return None

        traffic_response, live_traffic_warning = await self._try_live_traffic(
            data,
            route_stops,
            success_warnings=[order_warning, "Google Routes added live traffic ETA."],
        )
        if traffic_response is not None:
            return _with_order_method(traffic_response, "exact")
        if live_traffic_warning:
            osrm_response.warnings.insert(0, live_traffic_warning)
        return _with_order_method(osrm_response, "exact")

    async def _road_preview(
        self, travel_mode: TravelMode, stops: list[RoutePlanStop],
    ):
        """Road route where off-road attraction pins may snap farther than gates."""
        coordinates = [stop.coordinate for stop in stops]
        if hasattr(self.osrm_client, "preview_route_with_snap_limits"):
            return await self.osrm_client.preview_route_with_snap_limits(
                travel_mode=travel_mode,
                coordinates=coordinates,
                max_snap_meters=snap_limits(stops),
            )
        return await self.osrm_client.preview_route(
            travel_mode=travel_mode, coordinates=coordinates,
        )

    async def _try_live_traffic(
        self,
        data: RoutePreviewRequest | RouteOptimizeRequest,
        stops: list[RoutePlanStop],
        *,
        success_warnings: list[str] | None = None,
    ) -> tuple[RouteSummaryResponse | None, str | None]:
        if not _can_use_live_traffic(data, stops, self.google_routes_client):
            return None, None

        try:
            google_result = await self.google_routes_client.compute_route(
                travel_mode=data.travel_mode,
                coordinates=[stop.coordinate for stop in stops],
            )
            return _google_routes_response(
                travel_mode=data.travel_mode,
                stops=stops,
                google_result=google_result,
                warnings=success_warnings,
            ), None
        except (GoogleRoutesClientError, ValueError) as exc:
            return None, _traffic_warning(exc)

    async def _build_stops(
        self,
        data: RoutePreviewRequest | RouteOptimizeRequest,
    ) -> list[RoutePlanStop]:
        settings = get_settings()

        if len(data.destination_ids) > settings.route_max_destinations:
            raise LakbayAPIError(
                "Too many destinations were provided for one route request.",
                code="route_destination_limit_exceeded",
                status_code=status.HTTP_400_BAD_REQUEST,
                details={
                    "max_destinations": settings.route_max_destinations,
                    "destination_count": len(data.destination_ids),
                },
            )

        destinations = await self.routes.list_active_destinations_by_ids(
            list(data.destination_ids),
        )
        destination_by_id = {
            destination.destination_id: destination for destination in destinations
        }
        missing_ids = [
            destination_id
            for destination_id in data.destination_ids
            if destination_id not in destination_by_id
        ]

        if missing_ids:
            raise LakbayAPIError(
                "One or more destinations were not found or are inactive.",
                code="destination_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
                details={"destination_ids": missing_ids},
            )

        ordered_destinations = [
            destination_by_id[destination_id] for destination_id in data.destination_ids
        ]
        stops = []

        if data.origin is not None:
            stops.append(
                RoutePlanStop(
                    destination_id=None,
                    name=data.origin.label or "Origin",
                    lat=data.origin.lat,
                    lng=data.origin.lng,
                    is_origin=True,
                    coordinate_basis="origin",
                    island_group=data.origin.island_group,
                )
            )

        for destination in ordered_destinations:
            stops.append(_destination_to_stop(destination))

        self._require_valid_coordinates(stops)

        return stops

    def _require_valid_coordinates(self, stops: list[RoutePlanStop]) -> None:
        invalid_stops = [
            stop.destination_id
            for stop in stops
            if stop.lat is None
            or stop.lng is None
            or not (-90 <= stop.lat <= 90)
            or not (-180 <= stop.lng <= 180)
        ]

        if invalid_stops:
            raise LakbayAPIError(
                "One or more route stops have invalid coordinates.",
                code="invalid_route_coordinates",
                status_code=status.HTTP_400_BAD_REQUEST,
                details={"destination_ids": invalid_stops},
            )


def _destination_to_stop(destination: Destination) -> RoutePlanStop:
    has_verified_arrival = bool(
        destination.route_ready
        and destination.arrival_lat is not None
        and destination.arrival_lng is not None
        and destination.arrival_source_url
        and destination.arrival_verified_at
    )
    access_trail = getattr(destination, "access_trail_polyline", None)
    access_entry: tuple[float, float] | None = None
    if access_trail:
        try:
            decoded = decode_polyline5(access_trail)
            if len(decoded) >= 2:
                access_entry = decoded[0]
            else:
                access_trail = None
        except ValueError:
            access_trail = None

    if has_verified_arrival:
        lat, lng = destination.arrival_lat, destination.arrival_lng
    elif access_entry is not None:
        lat, lng = access_entry
    else:
        lat, lng = destination.lat, destination.lng

    return RoutePlanStop(
        destination_id=destination.destination_id,
        name=destination.name,
        lat=lat,
        lng=lng,
        coordinate_basis="verified_arrival" if has_verified_arrival else "attraction",
        island_group=destination.island_group,
        access_trail_polyline=access_trail,
    )


def _port_stop(port) -> RoutePlanStop:
    """A pier as an intermediate road waypoint (not a visited destination)."""
    return RoutePlanStop(
        destination_id=None,
        name=port.name,
        lat=port.lat,
        lng=port.lng,
        coordinate_basis="verified_arrival" if port.verified else "attraction",
        island_group=port.island_group,
        is_port=True,
    )


def _append_return_stop(
    stops: list[RoutePlanStop],
    return_to_origin: bool,
) -> list[RoutePlanStop]:
    if not return_to_origin or len(stops) <= 1:
        return stops

    return [*stops, stops[0]]


def _apply_stop_order(
    stops: list[RoutePlanStop],
    stop_order: list[int] | None,
    *,
    preserve_first: bool,
) -> list[RoutePlanStop]:
    if stop_order is None:
        raise ValueError("OSRM did not return an optimized stop order.")

    if sorted(stop_order) != list(range(len(stops))):
        raise ValueError("OSRM returned an invalid optimized stop order.")

    if preserve_first and stop_order[0] != 0:
        raise ValueError("OSRM moved the preserved first stop.")

    return [stops[index] for index in stop_order]


def _osrm_response(
    *,
    travel_mode: TravelMode,
    stops: list[RoutePlanStop],
    osrm_result: OSRMRouteResult,
    warnings: list[str] | None = None,
) -> RouteSummaryResponse:
    expected_leg_count = max(len(stops) - 1, 0)

    if len(osrm_result.legs) != expected_leg_count:
        raise ValueError("OSRM returned a leg count that does not match the stops.")

    verified = _arrival_points_verified(stops)
    legs = [
        _route_leg_from_osrm(
            order=index, start=start, end=end, leg=leg, show_steps=verified,
        )
        for index, (start, end, leg) in enumerate(
            zip(stops, stops[1:], osrm_result.legs),
            start=1,
        )
    ]
    ferries = [_ferry_crossing(item) for item in osrm_result.ferry_crossings]
    segments, gap_warnings = build_road_run_segments(stops, osrm_result)
    response_warnings = [
        *(warnings or []),
        *gap_warnings,
        *_arrival_warnings(stops),
        *(_ferry_warning(item) for item in ferries),
    ]
    polyline = osrm_result.polyline
    if polyline and any(getattr(stop, "access_trail_polyline", None) for stop in stops):
        non_estimated = [seg.polyline for seg in segments if not seg.is_estimated and seg.polyline]
        if len(non_estimated) >= 2:
            try:
                polyline = join_polylines5(non_estimated)
            except ValueError:
                polyline = osrm_result.polyline

    return RouteSummaryResponse(
        travel_mode=travel_mode,
        route_provider=osrm_result.provider,
        is_estimated=False,
        total_distance_km=_distance_km(osrm_result.total_distance_meters / 1000),
        total_duration_minutes=_duration_minutes(osrm_result.total_duration_seconds),
        stops=_response_stops(stops),
        legs=legs,
        polyline=polyline,
        polyline_encoding="polyline5" if polyline else None,
        arrival_points_verified=verified,
        warnings=response_warnings,
        ferry_crossings=ferries,
        segments=segments,
    )


def _ferry_crossing(crossing: OSRMFerryCrossing) -> RouteFerryCrossing:
    start = crossing.start or (None, None)
    end = crossing.end or (None, None)
    return RouteFerryCrossing(
        name=crossing.name,
        distance_km=_distance_km(crossing.distance_meters / 1000),
        duration_minutes=_duration_minutes(crossing.duration_seconds),
        from_lat=start[0],
        from_lng=start[1],
        to_lat=end[0],
        to_lng=end[1],
    )


def _ferry_warning(crossing: RouteFerryCrossing) -> str:
    name = f" ({crossing.name})" if crossing.name else ""
    return (
        f"This route includes a ferry crossing{name}, about "
        f"{crossing.duration_minutes} min on the boat. Check the schedule and "
        "fare before you travel; the travel time does not include waiting at "
        "the pier."
    )


def _google_routes_response(
    *,
    travel_mode: TravelMode,
    stops: list[RoutePlanStop],
    google_result: GoogleRouteResult,
    warnings: list[str] | None = None,
) -> RouteSummaryResponse:
    expected_leg_count = max(len(stops) - 1, 0)

    if len(google_result.legs) != expected_leg_count:
        raise ValueError("Google Routes returned a leg count that does not match the stops.")

    live_duration_minutes = _duration_minutes(google_result.total_duration_seconds)
    normal_duration_minutes = _duration_minutes(
        google_result.total_static_duration_seconds,
    )
    delay_minutes = max(live_duration_minutes - normal_duration_minutes, 0)
    traffic_level = _traffic_level(delay_minutes)
    verified = _arrival_points_verified(stops)
    legs = [
        _route_leg_from_google(
            order=index, start=start, end=end, leg=leg, show_steps=verified,
        )
        for index, (start, end, leg) in enumerate(
            zip(stops, stops[1:], google_result.legs),
            start=1,
        )
    ]
    response_warnings = [*(warnings or []), *_arrival_warnings(stops)]

    return RouteSummaryResponse(
        travel_mode=travel_mode,
        route_provider="google_routes",
        is_estimated=False,
        total_distance_km=_distance_km(google_result.total_distance_meters / 1000),
        total_duration_minutes=live_duration_minutes,
        stops=_response_stops(stops),
        legs=legs,
        polyline=google_result.polyline,
        polyline_encoding="polyline5" if google_result.polyline else None,
        arrival_points_verified=verified,
        warnings=response_warnings,
        traffic=RouteTrafficSummary(
            provider="google_routes",
            live_duration_minutes=live_duration_minutes,
            normal_duration_minutes=normal_duration_minutes,
            delay_minutes=delay_minutes,
            traffic_level=traffic_level,
            cache_hit=google_result.cache_hit,
            advisory=_traffic_advisory(traffic_level, delay_minutes),
        ),
    )


def _estimated_response(
    *,
    travel_mode: TravelMode,
    stops: list[RoutePlanStop],
    route_provider: str,
    warnings: list[str],
) -> RouteSummaryResponse:
    legs = _estimated_legs(travel_mode=travel_mode, stops=stops)
    total_distance = _distance_km(sum(leg.distance_km for leg in legs))
    total_duration = sum(leg.duration_minutes for leg in legs)

    return RouteSummaryResponse(
        travel_mode=travel_mode,
        route_provider=route_provider,
        is_estimated=True,
        total_distance_km=total_distance,
        total_duration_minutes=total_duration,
        stops=_response_stops(stops),
        legs=legs,
        warnings=[*warnings, *_arrival_warnings(stops)],
        arrival_points_verified=_arrival_points_verified(stops),
    )


def _empty_route_response(
    *,
    travel_mode: TravelMode,
    stops: list[RoutePlanStop],
    route_provider: str,
    is_estimated: bool,
) -> RouteSummaryResponse:
    return RouteSummaryResponse(
        travel_mode=travel_mode,
        route_provider=route_provider,
        is_estimated=is_estimated,
        total_distance_km=ZERO_DISTANCE,
        total_duration_minutes=0,
        stops=_response_stops(stops),
        legs=[],
        warnings=_arrival_warnings(stops),
        arrival_points_verified=_arrival_points_verified(stops),
    )


def _route_leg_from_osrm(
    *,
    order: int,
    start: RoutePlanStop,
    end: RoutePlanStop,
    leg: OSRMLeg,
    show_steps: bool,
) -> RouteLeg:
    return RouteLeg(
        order=order,
        from_destination_id=start.destination_id,
        to_destination_id=end.destination_id,
        from_name=start.name,
        to_name=end.name,
        distance_km=_distance_km(leg.distance_meters / 1000),
        duration_minutes=_duration_minutes(leg.duration_seconds),
        is_estimated=False,
        steps=[
            RouteDirectionStep(
                order=index,
                instruction=_osrm_instruction(step),
                distance_meters=round(step.distance_meters),
                duration_seconds=round(step.duration_seconds),
            )
            for index, step in enumerate(leg.steps, start=1)
        ] if show_steps else [],
    )


def _route_leg_from_google(
    *,
    order: int,
    start: RoutePlanStop,
    end: RoutePlanStop,
    leg: GoogleRouteLeg,
    show_steps: bool,
) -> RouteLeg:
    live_duration = _duration_minutes(leg.duration_seconds)
    normal_duration = _duration_minutes(leg.static_duration_seconds)
    delay_minutes = max(live_duration - normal_duration, 0)

    return RouteLeg(
        order=order,
        from_destination_id=start.destination_id,
        to_destination_id=end.destination_id,
        from_name=start.name,
        to_name=end.name,
        distance_km=_distance_km(leg.distance_meters / 1000),
        duration_minutes=live_duration,
        is_estimated=False,
        normal_duration_minutes=normal_duration,
        traffic_delay_minutes=delay_minutes,
        traffic_level=_traffic_level(delay_minutes),
        steps=[
            RouteDirectionStep(
                order=index,
                instruction=step.instruction,
                distance_meters=round(step.distance_meters),
                duration_seconds=round(step.duration_seconds),
            )
            for index, step in enumerate(leg.steps, start=1)
        ] if show_steps else [],
    )


def _estimated_legs(*, travel_mode: TravelMode, stops: list[RoutePlanStop]) -> list[RouteLeg]:
    legs = []

    for index, (start, end) in enumerate(zip(stops, stops[1:]), start=1):
        distance = _distance_km(_haversine_km(start, end))

        legs.append(
            RouteLeg(
                order=index,
                from_destination_id=start.destination_id,
                to_destination_id=end.destination_id,
                from_name=start.name,
                to_name=end.name,
                distance_km=distance,
                duration_minutes=_estimated_duration_minutes(
                    distance_km=distance,
                    travel_mode=travel_mode,
                ),
                is_estimated=True,
            )
        )

    return legs


def _response_stops(stops: list[RoutePlanStop]) -> list[RouteStop]:
    return [
        RouteStop(
            order=index,
            destination_id=stop.destination_id,
            name=stop.name,
            lat=stop.lat,
            lng=stop.lng,
            is_origin=stop.is_origin,
            coordinate_basis=stop.coordinate_basis,
        )
        for index, stop in enumerate(stops, start=1)
    ]


def _arrival_points_verified(stops: list[RoutePlanStop]) -> bool:
    destinations = [stop for stop in stops if not stop.is_origin]
    return bool(destinations) and all(
        stop.coordinate_basis == "verified_arrival" for stop in destinations
    )


def _arrival_warnings(stops: list[RoutePlanStop]) -> list[str]:
    if _arrival_points_verified(stops) or not any(not stop.is_origin for stop in stops):
        return []
    return [
        "Some stops use attraction coordinates. This route is a planning preview; "
        "confirm visitor entrances before using directions."
    ]


def _osrm_instruction(step: OSRMStep) -> str:
    road = f" onto {step.road_name}" if step.road_name else ""
    maneuver = step.maneuver_type.replace("_", " ").lower()
    modifier = (step.modifier or "").replace("uturn", "U-turn")
    if step.mode == "ferry":
        return f"Take the ferry{f' ({step.road_name})' if step.road_name else ''}"
    if maneuver == "depart":
        return f"Start{road}" if road else "Start the route"
    if maneuver == "arrive":
        return "Arrive at the destination"
    if maneuver in {"roundabout", "rotary"}:
        exit_text = f" and take exit {step.exit_number}" if step.exit_number else ""
        return f"Enter the roundabout{exit_text}{road}"
    if maneuver == "turn":
        return f"Turn {modifier}{road}".strip()
    if maneuver == "continue":
        return f"Continue{road}" if road else "Continue"
    if maneuver == "merge":
        return f"Merge {modifier}{road}".strip()
    return f"{maneuver.capitalize()} {modifier}{road}".strip()


def _heuristic_order(
    stops: list[RoutePlanStop],
    *,
    preserve_first: bool,
    roundtrip: bool,
) -> list[RoutePlanStop]:
    """Nearest neighbor plus 2-opt over straight-line distances."""
    costs = [[_haversine_km(start, end) for end in stops] for start in stops]
    order = nearest_neighbor_two_opt(costs, fixed_start=preserve_first, roundtrip=roundtrip)
    return [stops[index] for index in order]


def _with_order_method(
    response: RouteSummaryResponse,
    method: OrderMethod,
) -> RouteSummaryResponse:
    return response.model_copy(update={"order_method": method})


def _haversine_km(start: RoutePlanStop, end: RoutePlanStop) -> float:
    lat_1 = radians(start.lat)
    lat_2 = radians(end.lat)
    delta_lat = radians(end.lat - start.lat)
    delta_lng = radians(end.lng - start.lng)

    value = (
        sin(delta_lat / 2) ** 2
        + cos(lat_1) * cos(lat_2) * sin(delta_lng / 2) ** 2
    )

    return 2 * EARTH_RADIUS_KM * asin(sqrt(value))


def _estimated_duration_minutes(
    *,
    distance_km: Decimal,
    travel_mode: TravelMode,
) -> int:
    if distance_km == ZERO_DISTANCE:
        return 0

    speed = FALLBACK_SPEED_KMH[travel_mode]

    return max(1, int(((distance_km / speed) * Decimal("60")).to_integral_value()))


def _distance_km(value) -> Decimal:
    return Decimal(str(value)).quantize(Decimal("0.01"))


def _duration_minutes(seconds: float) -> int:
    if seconds <= 0:
        return 0

    return max(1, int((Decimal(str(seconds)) / Decimal("60")).to_integral_value()))


def _can_use_live_traffic(
    data: RoutePreviewRequest | RouteOptimizeRequest,
    stops: list[RoutePlanStop],
    google_routes_client: GoogleRoutesClient | None,
) -> bool:
    return (
        data.use_live_traffic
        and data.travel_mode == "driving"
        and len(stops) > 1
        and google_routes_client is not None
        and google_routes_client.is_configured
    )


def _traffic_warning(exc: GoogleRoutesClientError | ValueError) -> str:
    return f"Live traffic was unavailable ({exc}); route fallback was used."


def _traffic_level(delay_minutes: int) -> TrafficLevel:
    if delay_minutes <= 5:
        return "light"
    if delay_minutes <= 15:
        return "moderate"
    if delay_minutes <= 30:
        return "heavy"
    return "severe"


def _traffic_advisory(level: TrafficLevel, delay_minutes: int) -> str:
    if level == "severe":
        return (
            f"Severe traffic delay of about {delay_minutes} minutes. "
            "Leave earlier or choose another route."
        )
    if level == "heavy":
        return (
            f"Heavy traffic delay of about {delay_minutes} minutes. "
            "Consider adjusting departure time."
        )
    if level == "moderate":
        return f"Moderate traffic delay of about {delay_minutes} minutes. Add buffer time."
    return "Traffic is light on this route."

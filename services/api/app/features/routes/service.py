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
    chunk_stops,
    is_non_bisectable_road_error,
    network_from_links,
    planner_point,
    preview_road_chunk,
    spans_island_groups,
)
from app.features.routes.polyline import decode_polyline5, encode_polyline5, join_polylines5
from app.features.routes.repository import RouteRepository
from app.features.routes.snap_policy import (
    build_road_run_segments,
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
    RouteTrafficCongestionSegment,
    RouteTrafficInfo,
    RouteTrafficSummary,
    TrafficLevel,
    TrafficStatus,
    TravelMode,
)
from app.integrations.google_routes.client import GoogleRoutesClient
from app.integrations.google_routes.errors import GoogleRoutesClientError
from app.integrations.google_routes.schemas import GoogleRouteLeg, GoogleRouteResult
from app.integrations.mapbox_directions.client import (
    MAPBOX_MATRIX_MAX_COORDINATES,
    MAPBOX_OPTIMIZATION_MAX_COORDINATES,
    ChainedRoutingClient,
    MapboxDirectionsClient,
)
from app.integrations.osrm.client import OSRMClient
from app.integrations.osrm.errors import OSRMClientError, OSRMRouteNotFoundError
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


@dataclass(frozen=True)
class _RoadSubPart:
    stops: list[RoutePlanStop]
    result: OSRMRouteResult | None = None
    is_estimated: bool = False
    warning: str | None = None
    reason: str | None = None


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
        stops, skipped_ids, skipped_warnings = await self._build_stops_with_skipped(data)
        response = await self._preview_stops(data, stops)
        return self._attach_skipped(response, skipped_ids, skipped_warnings)

    async def _preview_stops(
        self,
        data: RoutePreviewRequest | RouteOptimizeRequest,
        stops: list[RoutePlanStop],
    ) -> RouteSummaryResponse:
        route_stops = _append_return_stop(stops, data.return_to_origin)

        if spans_island_groups(route_stops):
            return await self._multimodal_route(data, route_stops)

        if data.travel_mode == "public_transport":
            return self._apply_traffic_metadata(
                _estimated_response(
                    travel_mode=data.travel_mode,
                    stops=route_stops,
                    route_provider="stored_transportation_estimate",
                    warnings=[
                        "Public transit times are estimates. For fares, see the "
                        "transport rates listed for the place.",
                    ],
                ),
                use_live_traffic=data.use_live_traffic,
                road_results=[],
            )

        if len(route_stops) <= 1:
            return self._apply_traffic_metadata(
                _empty_route_response(
                    travel_mode=data.travel_mode,
                    stops=route_stops,
                    route_provider="none",
                    is_estimated=False,
                ),
                use_live_traffic=data.use_live_traffic,
                road_results=[],
            )

        traffic_response, live_traffic_warning = await self._try_live_traffic(
            data, route_stops,
        )
        if traffic_response is not None:
            return traffic_response

        warnings = [live_traffic_warning] if live_traffic_warning else []
        use_live = bool(data.use_live_traffic and data.travel_mode == "driving")
        response, road_results = await self._road_preview_resilient(
            data.travel_mode,
            route_stops,
            use_live_traffic=use_live,
            base_warnings=warnings,
        )
        return self._apply_traffic_metadata(
            response,
            use_live_traffic=data.use_live_traffic,
            road_results=road_results,
        )

    async def optimize_route(
        self,
        data: RouteOptimizeRequest,
    ) -> RouteSummaryResponse:
        stops, skipped_ids, skipped_warnings = await self._build_stops_with_skipped(data)

        preserve_first = data.origin is not None or data.preserve_first_destination

        if spans_island_groups(stops):
            response = await self._island_aware_optimize(
                data, stops, preserve_first=preserve_first,
            )
            return self._attach_skipped(response, skipped_ids, skipped_warnings)

        if data.travel_mode == "public_transport":
            ordered_stops = _heuristic_order(
                stops, preserve_first=preserve_first, roundtrip=data.return_to_origin,
            )
            route_stops = _append_return_stop(ordered_stops, data.return_to_origin)

            response = self._apply_traffic_metadata(
                _with_order_method(_estimated_response(
                    travel_mode=data.travel_mode,
                    stops=route_stops,
                    route_provider="stored_transportation_estimate",
                    warnings=[
                        "Public transit stop order is estimated from the places' "
                        "locations.",
                    ],
                ), "nearest_neighbor_2opt"),
                use_live_traffic=data.use_live_traffic,
                road_results=[],
            )
            return self._attach_skipped(response, skipped_ids, skipped_warnings)

        if len(stops) <= 1:
            response = self._apply_traffic_metadata(
                _empty_route_response(
                    travel_mode=data.travel_mode,
                    stops=stops,
                    route_provider="none",
                    is_estimated=False,
                ),
                use_live_traffic=data.use_live_traffic,
                road_results=[],
            )
            return self._attach_skipped(response, skipped_ids, skipped_warnings)

        # A fixed origin and one destination have no visit order to optimize.
        # OSRM Route also checks whether both coordinates snap near the road.
        if data.origin is not None and len(stops) == 2 and stops[0].is_origin:
            response = await self._preview_stops(data, stops)
            return self._attach_skipped(response, skipped_ids, skipped_warnings)

        # Small routes compare every possible order with OSRM travel times; larger
        # ones, or a failed exact attempt, use OSRM Trip, then matrix/2-opt.
        if len(stops) <= EXACT_ORDER_MAX_STOPS:
            exact_response = await self._exact_order_route(
                data, stops, preserve_first=preserve_first,
            )
            if exact_response is not None:
                return self._attach_skipped(exact_response, skipped_ids, skipped_warnings)

        order_warning = (
            "OSRM Trip returns a suggested route order; it is not "
            "guaranteed to be mathematically optimal."
        )
        use_live = bool(data.use_live_traffic and data.travel_mode == "driving")

        if len(stops) <= MAPBOX_OPTIMIZATION_MAX_COORDINATES:
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
                    return self._attach_skipped(
                        _with_order_method(traffic_response, "osrm_trip"),
                        skipped_ids,
                        skipped_warnings,
                    )
                if live_traffic_warning:
                    osrm_response.warnings.insert(0, live_traffic_warning)
                return self._attach_skipped(
                    self._apply_traffic_metadata(
                        _with_order_method(osrm_response, "osrm_trip"),
                        use_live_traffic=data.use_live_traffic,
                        road_results=[osrm_result],
                    ),
                    skipped_ids,
                    skipped_warnings,
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
                    return self._attach_skipped(
                        _with_order_method(traffic_response, "nearest_neighbor_2opt"),
                        skipped_ids,
                        skipped_warnings,
                    )

                warnings = [live_traffic_warning] if live_traffic_warning else []
                if _is_bisectable_road_error(exc):
                    road_resp, road_results = await self._road_preview_resilient(
                        data.travel_mode,
                        route_stops,
                        use_live_traffic=use_live,
                        base_warnings=[
                            *warnings,
                            "OSRM optimization was unavailable, so Haversine "
                            "nearest-neighbor ordering with 2-opt was used.",
                        ],
                    )
                    if road_results:
                        return self._attach_skipped(
                            self._apply_traffic_metadata(
                                _with_order_method(road_resp, "nearest_neighbor_2opt"),
                                use_live_traffic=data.use_live_traffic,
                                road_results=road_results,
                            ),
                            skipped_ids,
                            skipped_warnings,
                        )

                warnings.append(
                    "OSRM optimization was unavailable, so a Haversine "
                    "nearest-neighbor estimate with 2-opt was used."
                )
                return self._attach_skipped(
                    self._apply_traffic_metadata(
                        _with_order_method(_estimated_response(
                            travel_mode=data.travel_mode,
                            stops=route_stops,
                            route_provider="haversine",
                            warnings=warnings,
                        ), "nearest_neighbor_2opt"),
                        use_live_traffic=data.use_live_traffic,
                        road_results=[],
                    ),
                    skipped_ids,
                    skipped_warnings,
                )

        # >12 stops exceeds Mapbox Optimization limit: order with Matrix (<=25) or
        # Haversine 2-opt, then preview in overlapping <=25-coord road chunks.
        ordered_stops = await self._order_large_stop_list(
            travel_mode=data.travel_mode,
            stops=stops,
            preserve_first=preserve_first,
            roundtrip=data.return_to_origin,
        )
        route_stops = _append_return_stop(ordered_stops, data.return_to_origin)
        large_warning = (
            "Stops were ordered for multi-stop travel and routed in road segments."
        )
        traffic_response, live_traffic_warning = await self._try_live_traffic(
            data,
            route_stops,
            success_warnings=[large_warning],
        )
        if traffic_response is not None:
            return self._attach_skipped(
                _with_order_method(traffic_response, "nearest_neighbor_2opt"),
                skipped_ids,
                skipped_warnings,
            )
        warnings = [live_traffic_warning] if live_traffic_warning else []
        warnings.append(large_warning)
        road_resp, road_results = await self._road_preview_resilient(
            data.travel_mode,
            route_stops,
            use_live_traffic=use_live,
            base_warnings=warnings,
        )
        return self._attach_skipped(
            self._apply_traffic_metadata(
                _with_order_method(road_resp, "nearest_neighbor_2opt"),
                use_live_traffic=data.use_live_traffic,
                road_results=road_results,
            ),
            skipped_ids,
            skipped_warnings,
        )

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

        stops, skipped_input_ids, skipped_warnings = await self._build_stops_with_skipped(data)
        active_dest_ids = [
            stop.destination_id
            for stop in stops
            if not stop.is_origin and stop.destination_id is not None
        ]
        destinations = await self.routes.list_active_destinations_by_ids(
            list(dict.fromkeys(active_dest_ids)),
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

        raw_ordered_ids = [
            s.destination_id for s in plan.ordered_stops if s.destination_id is not None
        ]
        ordered_ids: list[int] = []
        for dest_id in raw_ordered_ids:
            if not ordered_ids or ordered_ids[-1] != dest_id:
                ordered_ids.append(dest_id)
        preview_req = RoutePreviewRequest(
            destination_ids=ordered_ids or active_dest_ids[:1],
            travel_mode=data.travel_mode,
            origin=data.origin,
            return_to_origin=data.return_to_origin,
            use_live_traffic=data.use_live_traffic,
        )
        route_summary = await self.preview_route(preview_req)
        route_summary = _with_order_method(route_summary, plan.order_method)

        merged_warnings = [*skipped_warnings, *plan.warnings]
        for w in route_summary.warnings:
            if w not in merged_warnings:
                merged_warnings.append(w)

        combined_skipped_ids = list(
            dict.fromkeys(
                [
                    *skipped_input_ids,
                    *(
                        s.destination_id
                        for s in plan.skipped_stops
                        if s.destination_id is not None
                    ),
                ]
            )
        )

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
            skipped_destination_ids=combined_skipped_ids,
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
        settings = get_settings()
        warnings = []
        if data.use_live_traffic and data.travel_mode == "driving":
            warnings.append(
                "Live traffic is not applied to routes with boat crossings."
            )
        verified = _arrival_points_verified(route_stops)
        use_live = bool(data.use_live_traffic and data.travel_mode == "driving")
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
            use_live_traffic=use_live,
            max_chunk_coordinates=min(settings.route_chunk_max_coordinates, 25),
            traffic_builder=lambda response, road_results: self._apply_traffic_metadata(
                response,
                use_live_traffic=data.use_live_traffic,
                road_results=road_results,
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
        use_live = bool(data.use_live_traffic and data.travel_mode == "driving")
        try:
            osrm_result = await self._road_preview(
                data.travel_mode, route_stops, use_live_traffic=use_live,
            )
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
        return self._apply_traffic_metadata(
            _with_order_method(osrm_response, "exact"),
            use_live_traffic=data.use_live_traffic,
            road_results=[osrm_result],
        )

    async def _road_preview(
        self,
        travel_mode: TravelMode,
        stops: list[RoutePlanStop],
        *,
        use_live_traffic: bool | None = None,
    ):
        """Road route where off-road attraction pins may snap farther than gates."""
        return await preview_road_chunk(
            self.osrm_client,
            travel_mode=travel_mode,
            stops=stops,
            use_live_traffic=use_live_traffic,
        )

    async def _order_large_stop_list(
        self,
        *,
        travel_mode: TravelMode,
        stops: list[RoutePlanStop],
        preserve_first: bool,
        roundtrip: bool,
    ) -> list[RoutePlanStop]:
        if len(stops) <= MAPBOX_MATRIX_MAX_COORDINATES and self.osrm_client is not None:
            try:
                matrix = await self.osrm_client.matrix(
                    travel_mode=travel_mode,
                    coordinates=[stop.coordinate for stop in stops],
                )
                durations = matrix.durations_seconds
                if all(value is not None for row in durations for value in row):
                    order = nearest_neighbor_two_opt(
                        durations, fixed_start=preserve_first, roundtrip=roundtrip,
                    )
                    return [stops[index] for index in order]
            except (OSRMClientError, ValueError) as exc:
                logger.info("Matrix ordering for large route skipped: %s", exc)
        return _heuristic_order(
            stops, preserve_first=preserve_first, roundtrip=roundtrip,
        )

    async def _road_preview_resilient(
        self,
        travel_mode: TravelMode,
        stops: list[RoutePlanStop],
        *,
        use_live_traffic: bool = False,
        base_warnings: list[str] | None = None,
    ) -> tuple[RouteSummaryResponse, list[OSRMRouteResult]]:
        settings = get_settings()
        max_coords = min(settings.route_chunk_max_coordinates, 25)
        chunks = chunk_stops(stops, max_coords=max_coords)
        sub_parts: list[_RoadSubPart] = []
        for chunk in chunks:
            sub_parts.extend(
                await self._preview_chunk_resilient(
                    travel_mode,
                    chunk,
                    use_live_traffic=use_live_traffic,
                )
            )

        warnings = list(base_warnings or [])
        road_results = [
            part.result
            for part in sub_parts
            if not part.is_estimated and part.result is not None
        ]

        if len(sub_parts) == 1 and not sub_parts[0].is_estimated and sub_parts[0].result is not None:
            return (
                _osrm_response(
                    travel_mode=travel_mode,
                    stops=sub_parts[0].stops,
                    osrm_result=sub_parts[0].result,
                    warnings=warnings,
                ),
                road_results,
            )

        if not road_results:
            if travel_mode == "driving":
                logger.warning("Driving OSRM route lookup failed across all segments.")
            warnings.append("OSRM was unavailable, so Haversine estimates were used.")
            return (
                _estimated_response(
                    travel_mode=travel_mode,
                    stops=stops,
                    route_provider="haversine",
                    warnings=warnings,
                ),
                [],
            )

        return (
            _merge_road_sub_parts(
                travel_mode=travel_mode,
                stops=stops,
                sub_parts=sub_parts,
                base_warnings=warnings,
            ),
            road_results,
        )

    async def _preview_chunk_resilient(
        self,
        travel_mode: TravelMode,
        stops: list[RoutePlanStop],
        *,
        use_live_traffic: bool = False,
    ) -> list[_RoadSubPart]:
        try:
            result = await self._road_preview(
                travel_mode, stops, use_live_traffic=use_live_traffic,
            )
            return [_RoadSubPart(stops=stops, result=result, is_estimated=False)]
        except (OSRMClientError, ValueError) as exc:
            if len(stops) <= 2 or not _is_bisectable_road_error(exc):
                if len(stops) == 2 and _is_bisectable_road_error(exc):
                    return [
                        _RoadSubPart(
                            stops=stops,
                            is_estimated=True,
                            reason="snap_or_road_unavailable",
                            warning=(
                                f"Road directions unavailable between {stops[0].name} and "
                                f"{stops[1].name}; straight-line estimate shown."
                            ),
                        )
                    ]
                return [
                    _RoadSubPart(
                        stops=stops,
                        is_estimated=True,
                        reason="road_provider_unavailable",
                        warning=None,
                    )
                ]
            mid = len(stops) // 2
            left = await self._preview_chunk_resilient(
                travel_mode, stops[: mid + 1], use_live_traffic=use_live_traffic,
            )
            right = await self._preview_chunk_resilient(
                travel_mode, stops[mid:], use_live_traffic=use_live_traffic,
            )
            return [*left, *right]

    def _apply_traffic_metadata(
        self,
        response: RouteSummaryResponse,
        *,
        use_live_traffic: bool,
        road_results: list[OSRMRouteResult],
    ) -> RouteSummaryResponse:
        if (
            not use_live_traffic
            or response.travel_mode != "driving"
            or len(response.stops) <= 1
        ):
            return response.model_copy(
                update={
                    "traffic": None,
                    "traffic_info": RouteTrafficInfo(status="disabled"),
                }
            )
        if response.route_provider == "google_routes" and response.traffic is not None:
            return response

        mapbox_results = [res for res in road_results if res.provider == "mapbox"]
        if mapbox_results:
            summary, info = _mapbox_traffic_from_results(mapbox_results)
            return response.model_copy(
                update={
                    "traffic": summary,
                    "traffic_info": info,
                }
            )

        has_provider = (
            _has_google_live_traffic(self.google_routes_client)
            or _has_mapbox_live_traffic(self.osrm_client)
        )
        status_val: TrafficStatus = (
            "limited_coverage" if has_provider else "unavailable_no_provider"
        )
        advisory = (
            "Live traffic was unavailable on this route; using standard road ETA."
            if has_provider
            else "No live traffic provider is configured; using standard road ETA."
        )
        return response.model_copy(
            update={
                "traffic": None,
                "traffic_info": RouteTrafficInfo(
                    status=status_val,
                    provider=(
                        None
                        if status_val == "unavailable_no_provider"
                        else response.route_provider
                    ),
                    delay_seconds=None,
                    congestion_segments=[],
                    advisory=advisory,
                ),
            }
        )

    def _attach_skipped(
        self,
        response: RouteSummaryResponse,
        skipped_ids: list[int],
        skipped_warnings: list[str],
    ) -> RouteSummaryResponse:
        if not skipped_ids and not skipped_warnings:
            return response
        merged_warnings = list(skipped_warnings)
        for warning in response.warnings:
            if warning not in merged_warnings:
                merged_warnings.append(warning)
        return response.model_copy(
            update={
                "skipped_destination_ids": skipped_ids,
                "warnings": merged_warnings,
            }
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
        if len(stops) > 27:
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
        stops, _, _ = await self._build_stops_with_skipped(data)
        return stops

    async def _build_stops_with_skipped(
        self,
        data: RoutePreviewRequest | RouteOptimizeRequest,
    ) -> tuple[list[RoutePlanStop], list[int], list[str]]:
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
            list(dict.fromkeys(data.destination_ids)),
        )
        destination_by_id = {
            destination.destination_id: destination for destination in destinations
        }
        missing_ids: list[int] = []
        valid_ids: list[int] = []
        for destination_id in data.destination_ids:
            if destination_id not in destination_by_id:
                if destination_id not in missing_ids:
                    missing_ids.append(destination_id)
            else:
                if not valid_ids or valid_ids[-1] != destination_id:
                    valid_ids.append(destination_id)

        routable_point_count = len(valid_ids) + (1 if data.origin is not None else 0)
        if missing_ids and (not valid_ids or routable_point_count < 2):
            raise LakbayAPIError(
                "One or more destinations were not found or are inactive.",
                code="destination_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
                details={"destination_ids": missing_ids},
            )

        skipped_warnings = (
            [
                f"Skipped unavailable destination(s): "
                f"{', '.join(str(item) for item in missing_ids)}."
            ]
            if missing_ids
            else []
        )

        ordered_destinations = [
            destination_by_id[destination_id] for destination_id in valid_ids
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

        return stops, missing_ids, skipped_warnings

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
    congestion_segments = [
        RouteTrafficCongestionSegment(
            leg_order=leg.order,
            level=leg.traffic_level or "unknown",
            distance_meters=round(float(leg.distance_km) * 1000),
            duration_seconds=leg.duration_minutes * 60,
        )
        for leg in legs
    ]
    delay_seconds = max(0, round(google_result.delay_seconds))
    advisory = _traffic_advisory(traffic_level, delay_minutes)

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
            advisory=advisory,
            status="live",
            delay_seconds=delay_seconds,
            congestion_segments=congestion_segments,
        ),
        traffic_info=RouteTrafficInfo(
            status="live",
            provider="google_routes",
            delay_seconds=delay_seconds,
            congestion_segments=congestion_segments,
            advisory=advisory,
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


_MAPBOX_TO_TRAFFIC_LEVEL: dict[str, TrafficLevel] = {
    "low": "light",
    "light": "light",
    "moderate": "moderate",
    "heavy": "heavy",
    "severe": "severe",
}
_TRAFFIC_SEVERITY_RANK: dict[TrafficLevel, int] = {
    "unknown": 0,
    "light": 1,
    "moderate": 2,
    "heavy": 3,
    "severe": 4,
}


def _has_google_live_traffic(google_routes_client: GoogleRoutesClient | None) -> bool:
    return bool(google_routes_client is not None and google_routes_client.is_configured)


def _has_mapbox_live_traffic(osrm_client: OSRMClient | None) -> bool:
    if osrm_client is None:
        return False
    if isinstance(osrm_client, MapboxDirectionsClient):
        return (
            getattr(osrm_client.settings, "mapbox_directions_profile_driving", "")
            == "driving-traffic"
        )
    if isinstance(osrm_client, ChainedRoutingClient):
        return bool(getattr(osrm_client, "has_mapbox_client", False)) and (
            getattr(osrm_client.settings, "mapbox_directions_profile_driving", "")
            == "driving-traffic"
        )
    return getattr(osrm_client, "provider_name", None) == "mapbox"


def _is_bisectable_road_error(exc: Exception) -> bool:
    if is_non_bisectable_road_error(exc):
        return False
    if isinstance(exc, (OSRMRouteNotFoundError, ValueError)):
        return True
    msg = str(exc).lower()
    return any(
        token in msg
        for token in ("no road", "no route", "too far", "snap", "waypoint", "segment")
    )


def _merge_road_sub_parts(
    *,
    travel_mode: TravelMode,
    stops: list[RoutePlanStop],
    sub_parts: list[_RoadSubPart],
    base_warnings: list[str],
) -> RouteSummaryResponse:
    verified = _arrival_points_verified(stops)
    legs: list[RouteLeg] = []
    segments: list[RouteSegment] = []
    ferries: list[RouteFerryCrossing] = []
    response_warnings = list(base_warnings)
    total_distance_meters = 0.0
    total_duration_seconds = 0.0
    providers: list[str] = []

    def add_warning(msg: str | None) -> None:
        if msg and msg not in response_warnings:
            response_warnings.append(msg)

    for part in sub_parts:
        if not part.is_estimated and part.result is not None:
            providers.append(part.result.provider)
            total_distance_meters += part.result.total_distance_meters
            total_duration_seconds += part.result.total_duration_seconds
            for start, end, osrm_leg in zip(
                part.stops, part.stops[1:], part.result.legs,
            ):
                legs.append(
                    _route_leg_from_osrm(
                        order=len(legs) + 1,
                        start=start,
                        end=end,
                        leg=osrm_leg,
                        show_steps=verified,
                    )
                )
            for item in part.result.ferry_crossings:
                ferries.append(_ferry_crossing(item))
            part_segments, gap_warnings = build_road_run_segments(
                part.stops,
                part.result,
                start_order=len(segments) + 1,
                emit_when_plain=True,
            )
            segments.extend(part_segments)
            for msg in gap_warnings:
                add_warning(msg)
        else:
            add_warning(part.warning)
            for start, end in zip(part.stops, part.stops[1:]):
                est_leg = _estimated_legs(travel_mode=travel_mode, stops=[start, end])[0]
                legs.append(
                    est_leg.model_copy(
                        update={
                            "order": len(legs) + 1,
                            "mode": "unrouted",
                            "warning": part.warning,
                            "reason": part.reason,
                        }
                    )
                )
                total_distance_meters += float(est_leg.distance_km) * 1000.0
                total_duration_seconds += float(est_leg.duration_minutes) * 60.0
                segments.append(
                    RouteSegment(
                        order=len(segments) + 1,
                        mode="unrouted",
                        from_name=start.name,
                        to_name=end.name,
                        polyline=encode_polyline5(
                            [(start.lat, start.lng), (end.lat, end.lng)]
                        ),
                        is_estimated=True,
                        warning=part.warning,
                        reason=part.reason,
                    )
                )

    for msg in _arrival_warnings(stops):
        add_warning(msg)
    for item in ferries:
        add_warning(_ferry_warning(item))

    any_estimated = any(part.is_estimated for part in sub_parts)
    polyline: str | None = None
    if not any_estimated:
        solid_polylines = [
            seg.polyline for seg in segments if not seg.is_estimated and seg.polyline
        ]
        if solid_polylines:
            try:
                polyline = join_polylines5(solid_polylines)
            except ValueError:
                polyline = None

    return RouteSummaryResponse(
        travel_mode=travel_mode,
        route_provider=providers[0] if providers else "haversine",
        is_estimated=any_estimated,
        total_distance_km=_distance_km(total_distance_meters / 1000.0),
        total_duration_minutes=_duration_minutes(total_duration_seconds),
        stops=_response_stops(stops),
        legs=legs,
        polyline=polyline,
        polyline_encoding="polyline5" if polyline else None,
        arrival_points_verified=verified,
        warnings=response_warnings,
        ferry_crossings=ferries,
        segments=segments,
    )


def _mapbox_traffic_from_results(
    results: list[OSRMRouteResult],
) -> tuple[RouteTrafficSummary | None, RouteTrafficInfo]:
    has_known_congestion = False
    has_typical_duration = False

    for res in results:
        if res.duration_typical_seconds is not None:
            has_typical_duration = True
        for leg in res.legs:
            if leg.duration_typical_seconds is not None:
                has_typical_duration = True
            if any(
                _MAPBOX_TO_TRAFFIC_LEVEL.get(lvl.lower(), "unknown") != "unknown"
                for lvl in leg.congestion_levels
            ):
                has_known_congestion = True

    if not has_known_congestion and not has_typical_duration:
        return (
            None,
            RouteTrafficInfo(
                status="limited_coverage",
                provider="mapbox",
                delay_seconds=None,
                congestion_segments=[],
                advisory=(
                    "Live traffic coverage is limited on this route; "
                    "using standard road ETA."
                ),
            ),
        )

    congestion_segments: list[RouteTrafficCongestionSegment] = []
    global_leg_order = 0

    for res in results:
        decoded_pts: list[tuple[float, float]] = []
        if res.polyline:
            try:
                decoded_pts = decode_polyline5(res.polyline)
            except ValueError:
                decoded_pts = []
        total_edge_annotations = sum(len(leg.congestion_levels) for leg in res.legs)
        can_align_polyline = (
            bool(decoded_pts)
            and total_edge_annotations > 0
            and total_edge_annotations == len(decoded_pts) - 1
        )
        edge_cursor = 0
        for leg in res.legs:
            global_leg_order += 1
            mapped = [
                _MAPBOX_TO_TRAFFIC_LEVEL.get(raw.lower(), "unknown")
                for raw in leg.congestion_levels
            ]
            if can_align_polyline and mapped:
                span_start = 0
                while span_start < len(mapped):
                    lvl = mapped[span_start]
                    span_end = span_start + 1
                    while span_end < len(mapped) and mapped[span_end] == lvl:
                        span_end += 1
                    pts_slice = decoded_pts[
                        edge_cursor + span_start : edge_cursor + span_end + 1
                    ]
                    dist_slice = leg.annotation_distances[span_start:span_end]
                    dur_slice = leg.annotation_durations[span_start:span_end]
                    congestion_segments.append(
                        RouteTrafficCongestionSegment(
                            leg_order=global_leg_order,
                            level=lvl,
                            polyline=(
                                encode_polyline5(pts_slice)
                                if len(pts_slice) >= 2
                                else None
                            ),
                            distance_meters=(
                                round(sum(dist_slice))
                                if len(dist_slice) == (span_end - span_start)
                                else None
                            ),
                            duration_seconds=(
                                round(sum(dur_slice))
                                if len(dur_slice) == (span_end - span_start)
                                else None
                            ),
                        )
                    )
                    span_start = span_end
                edge_cursor += len(mapped)
            else:
                non_unknown = [lvl for lvl in mapped if lvl != "unknown"]
                leg_level: TrafficLevel = (
                    max(non_unknown, key=lambda lvl: _TRAFFIC_SEVERITY_RANK[lvl])
                    if non_unknown
                    else "unknown"
                )
                congestion_segments.append(
                    RouteTrafficCongestionSegment(
                        leg_order=global_leg_order,
                        level=leg_level,
                        polyline=None,
                        distance_meters=round(leg.distance_meters),
                        duration_seconds=round(leg.duration_seconds),
                    )
                )

    live_seconds = sum(res.total_duration_seconds for res in results)
    typical_parts: list[float] = []
    all_have_typical = True
    for res in results:
        if res.duration_typical_seconds is not None:
            typical_parts.append(res.duration_typical_seconds)
        elif res.legs and all(l.duration_typical_seconds is not None for l in res.legs):
            typical_parts.append(sum(l.duration_typical_seconds or 0.0 for l in res.legs))
        else:
            all_have_typical = False
            break

    if all_have_typical and typical_parts:
        typical_seconds = sum(typical_parts)
        delay_seconds: int | None = max(0, round(live_seconds - typical_seconds))
        delay_minutes = round(delay_seconds / 60)
        normal_minutes = _duration_minutes(typical_seconds)
        traffic_level = _traffic_level(delay_minutes)
    else:
        delay_seconds = None
        delay_minutes = 0
        normal_minutes = _duration_minutes(live_seconds)
        non_unknown_levels = [
            seg.level for seg in congestion_segments if seg.level != "unknown"
        ]
        traffic_level = (
            max(non_unknown_levels, key=lambda lvl: _TRAFFIC_SEVERITY_RANK[lvl])
            if non_unknown_levels
            else "light"
        )

    live_minutes = _duration_minutes(live_seconds)
    advisory = _traffic_advisory(traffic_level, delay_minutes)
    return (
        RouteTrafficSummary(
            provider="mapbox",
            live_duration_minutes=live_minutes,
            normal_duration_minutes=normal_minutes,
            delay_minutes=delay_minutes,
            traffic_level=traffic_level,
            cache_hit=False,
            advisory=advisory,
            status="live",
            delay_seconds=delay_seconds,
            congestion_segments=congestion_segments,
        ),
        RouteTrafficInfo(
            status="live",
            provider="mapbox",
            delay_seconds=delay_seconds,
            congestion_segments=congestion_segments,
            advisory=advisory,
        ),
    )

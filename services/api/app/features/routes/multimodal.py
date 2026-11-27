"""Build routes that drive to a pier, cross by boat, and drive on.

Used by RouteService when consecutive stops are on different island groups.
Road runs (stretches between boat rides) go to the road router; boat rides
come from the sea-link planner. The response keeps one leg per stop-to-stop
pair, so callers that check stop coverage keep working, and adds ``segments``
so the app can draw road and sea parts differently.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass, field, replace
from decimal import Decimal
from typing import TYPE_CHECKING

from app.features.routes.polyline import encode_polyline5, join_polylines5, decode_polyline5
from app.features.routes.schemas import (
    RouteDirectionStep,
    RouteLeg,
    RouteSeaCrossing,
    RouteSegment,
    RouteSummaryResponse,
    TravelMode,
)
from app.features.routes.sea_planner import (
    PlannerLink,
    PlannerPoint,
    PlannerPort,
    SeaHop,
    SeaNetwork,
    haversine_km,
)
from app.features.sea_links.models import MAINLAND, SeaLink
from app.features.routes.snap_policy import (
    build_road_run_segments,
    snap_limits,
)
from app.integrations.osrm.errors import OSRMClientError, OSRMConfigurationError
from app.integrations.osrm.schemas import OSRMRouteResult

if TYPE_CHECKING:
    from app.features.routes.service import RoutePlanStop

logger = logging.getLogger(__name__)

VESSEL_LABELS = {
    "roro_barge": "RoRo barge",
    "passenger_ferry": "passenger ferry",
    "pump_boat": "pump boat",
}


def network_from_links(links: list[SeaLink]) -> SeaNetwork:
    ports: dict[int, PlannerPort] = {}
    planner_links = []
    for link in links:
        for port in (link.from_port, link.to_port):
            ports[port.port_id] = PlannerPort(
                port_id=port.port_id, name=port.name, lat=port.lat, lng=port.lng,
                island_group=port.island_group, verified=port.verified_at is not None,
            )
        planner_links.append(PlannerLink(
            link_id=link.link_id,
            from_port_id=link.from_port_id,
            to_port_id=link.to_port_id,
            vessel_type=link.vessel_type,
            allows_private_vehicle=link.allows_private_vehicle,
            crossing_minutes=link.crossing_minutes,
            typical_wait_minutes=link.typical_wait_minutes,
            bidirectional=link.bidirectional,
            schedule_text=link.schedule_text,
            fare_passenger=link.fare_passenger,
            fare_vehicle=link.fare_vehicle,
            geometry_polyline=link.geometry_polyline,
            verified=link.verified_at is not None,
        ))
    return SeaNetwork(list(ports.values()), planner_links)


def spans_island_groups(stops: list["RoutePlanStop"]) -> bool:
    return len({stop.island_group or MAINLAND for stop in stops}) > 1


def planner_point(stop: "RoutePlanStop") -> PlannerPoint:
    return PlannerPoint(lat=stop.lat, lng=stop.lng, island_group=stop.island_group)


@dataclass
class _Run:
    """Road-connected coordinates between boat rides."""

    stops: list["RoutePlanStop"] = field(default_factory=list)
    # For each run leg (stops[i] -> stops[i+1]): the stop-to-stop leg it belongs to.
    leg_index: list[int] = field(default_factory=list)
    result: OSRMRouteResult | None = None
    estimated: bool = False


@dataclass
class _Crossing:
    leg_index: int
    hop: SeaHop


def chunk_stops(
    stops: list["RoutePlanStop"], max_coords: int = 25,
) -> list[list["RoutePlanStop"]]:
    """Split stops into overlapping windows of at most [max_coords] coordinates."""
    if max_coords < 2:
        max_coords = 2
    if len(stops) <= max_coords:
        return [stops] if len(stops) >= 2 else []
    step = max_coords - 1
    return [
        stops[index : index + max_coords]
        for index in range(0, len(stops) - 1, step)
    ]


def is_non_bisectable_road_error(exc: Exception) -> bool:
    """True for provider config errors, 5xx responses, or transport/timeout outages."""
    if isinstance(exc, OSRMConfigurationError):
        return True
    if isinstance(exc, OSRMClientError):
        if exc.status_code is not None and exc.status_code >= 500:
            return True
        msg = str(exc).lower()
        if (
            "request failed" in msg
            or "timed out" in msg
            or "server error" in msg
            or "quota" in msg
        ):
            return True
    return False


async def preview_road_chunk(
    road_client,
    *,
    travel_mode: TravelMode,
    stops: list["RoutePlanStop"],
    use_live_traffic: bool | None = None,
) -> OSRMRouteResult:
    coordinates = [stop.coordinate for stop in stops]
    if hasattr(road_client, "preview_route_with_options"):
        result = await road_client.preview_route_with_options(
            travel_mode=travel_mode,
            coordinates=coordinates,
            max_snap_meters=snap_limits(stops),
            use_live_traffic=use_live_traffic,
        )
    elif hasattr(road_client, "preview_route_with_snap_limits"):
        result = await road_client.preview_route_with_snap_limits(
            travel_mode=travel_mode,
            coordinates=coordinates,
            max_snap_meters=snap_limits(stops),
        )
    else:
        result = await road_client.preview_route(
            travel_mode=travel_mode,
            coordinates=coordinates,
        )
    if len(result.legs) != len(stops) - 1:
        raise ValueError("Road router leg count did not match the stops.")
    return result


def merge_osrm_results(results: list[OSRMRouteResult]) -> OSRMRouteResult:
    """Merge consecutive overlapping OSRMRouteResult chunks into one result."""
    if len(results) == 1:
        return results[0]
    polylines = [res.polyline for res in results if res.polyline]
    merged_polyline: str | None = None
    if len(polylines) == len(results) and polylines:
        try:
            merged_polyline = join_polylines5(polylines)
        except ValueError:
            merged_polyline = None
    merged_snaps: list[tuple[float, float, float] | None] = []
    for idx, res in enumerate(results):
        snaps = list(res.waypoint_snaps or [])
        if idx > 0 and snaps and merged_snaps:
            snaps = snaps[1:]
        merged_snaps.extend(snaps)
    typical_values = [res.duration_typical_seconds for res in results]
    total_typical = (
        sum(v for v in typical_values if v is not None)
        if all(v is not None for v in typical_values)
        else None
    )
    return OSRMRouteResult(
        total_distance_meters=sum(res.total_distance_meters for res in results),
        total_duration_seconds=sum(res.total_duration_seconds for res in results),
        legs=[leg for res in results for leg in res.legs],
        polyline=merged_polyline,
        ferry_crossings=[f for res in results for f in res.ferry_crossings],
        provider=results[0].provider,
        waypoint_snaps=merged_snaps,
        duration_typical_seconds=total_typical,
        live_traffic_requested=any(res.live_traffic_requested for res in results),
    )


async def _split_failed_run(
    road_client,
    *,
    travel_mode: TravelMode,
    run: _Run,
    use_live_traffic: bool | None = None,
) -> list[_Run]:
    """Bisect a failing multi-stop road run so valid legs keep real road geometry."""
    try:
        result = await preview_road_chunk(
            road_client,
            travel_mode=travel_mode,
            stops=run.stops,
            use_live_traffic=use_live_traffic,
        )
        return [_Run(stops=run.stops, leg_index=run.leg_index, result=result, estimated=False)]
    except (OSRMClientError, ValueError) as exc:
        if len(run.stops) <= 2 or is_non_bisectable_road_error(exc):
            return [_Run(stops=run.stops, leg_index=run.leg_index, result=None, estimated=True)]
        mid = len(run.stops) // 2
        left = _Run(stops=run.stops[: mid + 1], leg_index=run.leg_index[:mid])
        right = _Run(stops=run.stops[mid:], leg_index=run.leg_index[mid:])
        left_runs = await _split_failed_run(
            road_client, travel_mode=travel_mode, run=left, use_live_traffic=use_live_traffic,
        )
        right_runs = await _split_failed_run(
            road_client, travel_mode=travel_mode, run=right, use_live_traffic=use_live_traffic,
        )
        return [*left_runs, *right_runs]


async def build_multimodal_response(
    *,
    road_client,
    travel_mode: TravelMode,
    stops: list["RoutePlanStop"],
    network: SeaNetwork,
    port_stop_factory,
    base_warnings: list[str],
    estimated_leg_factory,
    road_leg_factory,
    estimated_response_factory,
    use_live_traffic: bool = False,
    max_chunk_coordinates: int = 25,
    traffic_builder=None,
) -> RouteSummaryResponse:
    driving = travel_mode == "driving"

    paths = []
    unconnected: list[str] = []
    for start, end in zip(stops, stops[1:]):
        path = network.find_path(planner_point(start), planner_point(end), driving=driving)
        if path is None:
            group = end.island_group or MAINLAND
            if (start.island_group or MAINLAND) != MAINLAND and group == MAINLAND:
                group = start.island_group
            if group not in unconnected:
                unconnected.append(group)
        paths.append(path)

    if unconnected:
        response = estimated_response_factory(
            stops,
            [
                *base_warnings,
                "No pier connection is on file for "
                + ", ".join(sorted(unconnected))
                + ". The route cannot be drawn by road; ask a Lakbay admin to add the "
                "boat link, or plan the crossing separately.",
            ],
        )
        return response.model_copy(update={"unconnected_island_groups": sorted(unconnected)})

    runs: list[_Run] = [_Run(stops=[stops[0]])]
    crossings: list[_Crossing] = []
    # Ordered parts of the trip: ("run", run index) or ("sea", crossing index).
    parts: list[tuple[str, int]] = [("run", 0)]

    def extend_run(stop: "RoutePlanStop", leg_index: int) -> None:
        run = runs[-1]
        last = run.stops[-1]
        if (last.lat, last.lng) == (stop.lat, stop.lng):
            return
        run.stops.append(stop)
        run.leg_index.append(leg_index)

    for leg_index, (end, path) in enumerate(zip(stops[1:], paths)):
        for hop in path.hops:
            extend_run(port_stop_factory(hop.board), leg_index)
            crossings.append(_Crossing(leg_index=leg_index, hop=hop))
            parts.append(("sea", len(crossings) - 1))
            runs.append(_Run(stops=[port_stop_factory(hop.land)]))
            parts.append(("run", len(runs) - 1))
        extend_run(end, leg_index)

    warnings = list(base_warnings)
    expanded_runs: list[_Run] = []
    expanded_parts: list[tuple[str, int]] = []
    for kind, index in parts:
        if kind != "run":
            expanded_parts.append((kind, index))
            continue
        run = runs[index]
        if len(run.stops) < 2:
            expanded_runs.append(run)
            expanded_parts.append(("run", len(expanded_runs) - 1))
            continue
        if travel_mode == "public_transport":
            expanded_runs.append(
                _Run(stops=run.stops, leg_index=run.leg_index, estimated=True),
            )
            expanded_parts.append(("run", len(expanded_runs) - 1))
            continue

        windows = chunk_stops(run.stops, max_coords=max_chunk_coordinates)
        if len(windows) == 1:
            sub_runs = await _split_failed_run(
                road_client,
                travel_mode=travel_mode,
                run=run,
                use_live_traffic=use_live_traffic,
            )
        else:
            sub_runs = []
            offset = 0
            for window in windows:
                leg_slice = run.leg_index[offset : offset + len(window) - 1]
                offset += len(window) - 1
                sub_runs.extend(
                    await _split_failed_run(
                        road_client,
                        travel_mode=travel_mode,
                        run=_Run(stops=window, leg_index=leg_slice),
                        use_live_traffic=use_live_traffic,
                    )
                )

        for sub_run in sub_runs:
            if sub_run.estimated:
                message = (
                    f"The road between {sub_run.stops[0].name} and {sub_run.stops[-1].name} could "
                    "not be routed, so that part uses a straight-line estimate."
                )
                if message not in warnings:
                    warnings.append(message)
            expanded_runs.append(sub_run)
            expanded_parts.append(("run", len(expanded_runs) - 1))

    runs = expanded_runs
    parts = expanded_parts

    # Assemble one RouteLeg per stop-to-stop pair.
    leg_count = len(stops) - 1
    distance = [Decimal("0.00")] * leg_count
    duration = [0] * leg_count
    estimated = [False] * leg_count
    steps: list[list[RouteDirectionStep]] = [[] for _ in range(leg_count)]
    leg_crossings: list[list[RouteSeaCrossing]] = [[] for _ in range(leg_count)]

    run_parts_by_leg: dict[int, list[tuple[str, object]]] = {}
    for kind, index in parts:
        if kind == "run":
            run = runs[index]
            for run_leg, leg_index in enumerate(run.leg_index):
                start, end = run.stops[run_leg], run.stops[run_leg + 1]
                if run.estimated or run.result is None:
                    leg = estimated_leg_factory(travel_mode, start, end)
                    estimated[leg_index] = True
                else:
                    leg = road_leg_factory(start, end, run.result.legs[run_leg])
                distance[leg_index] += leg.distance_km
                duration[leg_index] += leg.duration_minutes
                steps[leg_index].extend(leg.steps)
        else:
            crossing = crossings[index]
            hop = crossing.hop
            sea_km = Decimal(str(round(haversine_km(hop.board, hop.land), 2))).quantize(
                Decimal("0.01"),
            )
            item = RouteSeaCrossing(
                order=index + 1,
                leg_order=crossing.leg_index + 1,
                link_id=hop.link.link_id,
                vessel_type=hop.link.vessel_type,
                board_port=hop.board.name,
                land_port=hop.land.name,
                board_lat=hop.board.lat,
                board_lng=hop.board.lng,
                land_lat=hop.land.lat,
                land_lng=hop.land.lng,
                distance_km=sea_km,
                crossing_minutes=hop.link.crossing_minutes,
                typical_wait_minutes=hop.link.typical_wait_minutes,
                allows_private_vehicle=hop.link.allows_private_vehicle,
                schedule_text=hop.link.schedule_text,
                fare_passenger=hop.link.fare_passenger,
                fare_vehicle=hop.link.fare_vehicle,
                verified=hop.link.verified and hop.board.verified and hop.land.verified,
            )
            leg_crossings[crossing.leg_index].append(item)
            distance[crossing.leg_index] += sea_km
            duration[crossing.leg_index] += (
                hop.link.crossing_minutes + hop.link.typical_wait_minutes
            )
            steps[crossing.leg_index].append(RouteDirectionStep(
                order=1,
                instruction=(
                    f"Board the {VESSEL_LABELS.get(hop.link.vessel_type, 'boat')} at "
                    f"{hop.board.name} to {hop.land.name}"
                ),
                distance_meters=round(float(sea_km) * 1000),
                duration_seconds=hop.link.crossing_minutes * 60,
            ))

    legs = []
    for leg_index, (start, end) in enumerate(zip(stops, stops[1:])):
        numbered = [
            step.model_copy(update={"order": number})
            for number, step in enumerate(steps[leg_index], start=1)
        ]
        legs.append(RouteLeg(
            order=leg_index + 1,
            from_destination_id=start.destination_id,
            to_destination_id=end.destination_id,
            from_name=start.name,
            to_name=end.name,
            distance_km=distance[leg_index],
            duration_minutes=duration[leg_index],
            is_estimated=estimated[leg_index],
            steps=numbered,
            sea_crossings=leg_crossings[leg_index],
        ))

    segments: list[RouteSegment] = []
    for kind, index in parts:
        if kind == "run":
            run = runs[index]
            if len(run.stops) < 2:
                continue
            if not run.estimated and run.result is not None and run.result.polyline:
                run_segments, run_warnings = build_road_run_segments(
                    run.stops,
                    run.result,
                    start_order=len(segments) + 1,
                    emit_when_plain=True,
                )
                for message in run_warnings:
                    if message not in warnings:
                        warnings.append(message)
                segments.extend(run_segments)
            else:
                segments.append(RouteSegment(
                    order=len(segments) + 1,
                    mode="road",
                    from_name=run.stops[0].name,
                    to_name=run.stops[-1].name,
                    # Unrouted runs get a straight stop-to-stop connector the app
                    # draws dashed, never as a drivable road.
                    polyline=encode_polyline5([(stop.lat, stop.lng) for stop in run.stops]),
                    is_estimated=True,
                ))
        else:
            hop = crossings[index].hop
            segments.append(RouteSegment(
                order=len(segments) + 1, mode="sea",
                from_name=hop.board.name, to_name=hop.land.name,
                polyline=_sea_polyline(hop),
            ))

    sea_crossings = [item for leg in legs for item in leg.sea_crossings]
    for item in sea_crossings:
        warnings.append(_crossing_warning(item, driving=driving))

    road_providers = [run.result.provider for run in runs if run.result is not None]
    any_estimated = any(estimated) or not road_providers
    combined = None
    # Dashed off-road last stretches do not stop the drivable parts from being
    # one combined road line; an unrouted road run does.
    if segments and not any(run.estimated for run in runs if len(run.stops) >= 2):
        solid_polylines = [
            segment.polyline
            for segment in segments
            if not segment.is_estimated and segment.polyline
        ]
        if solid_polylines:
            combined = join_polylines5(solid_polylines)

    total_distance = sum(distance, Decimal("0.00")).quantize(Decimal("0.01"))
    sea_distance = sum(
        (item.distance_km for item in sea_crossings), Decimal("0.00"),
    ).quantize(Decimal("0.01"))
    base = estimated_response_factory(stops, [])
    response = base.model_copy(update={
        "route_provider": f"{road_providers[0] if road_providers else 'haversine'}+sea_links",
        "is_estimated": any_estimated,
        "total_distance_km": total_distance,
        "total_duration_minutes": sum(duration),
        "legs": legs,
        "polyline": combined,
        "polyline_encoding": "polyline5" if combined else None,
        "warnings": [*warnings, *base.warnings],
        "sea_crossings": sea_crossings,
        "sea_distance_km": sea_distance,
        "segments": segments,
    })
    if traffic_builder is not None:
        road_results = [run.result for run in runs if run.result is not None]
        response = traffic_builder(response, road_results)
    return response


def _sea_polyline(hop: SeaHop) -> str:
    if hop.link.geometry_polyline:
        try:
            points = decode_polyline5(hop.link.geometry_polyline)
            if len(points) >= 2:
                if hop.reversed_geometry:
                    points.reverse()
                return encode_polyline5(points)
        except ValueError:
            pass
    return encode_polyline5([(hop.board.lat, hop.board.lng), (hop.land.lat, hop.land.lng)])


def _crossing_warning(item: RouteSeaCrossing, *, driving: bool) -> str:
    vessel = VESSEL_LABELS.get(item.vessel_type, "boat")
    text = (
        f"Board the {vessel} at {item.board_port} to {item.land_port}: about "
        f"{item.crossing_minutes} min on the water plus ~{item.typical_wait_minutes} min "
        "waiting, both included in the travel time."
    )
    if driving and not item.allows_private_vehicle:
        text += " Vehicles cannot board this boat; park at the pier and continue on foot or by local transport."
    if item.schedule_text:
        text += f" Schedule: {item.schedule_text}"
    if not item.verified:
        text += " Pier location, schedule and fares are not yet verified."
    return text

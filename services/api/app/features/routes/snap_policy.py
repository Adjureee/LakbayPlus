"""How far the road router may move each stop to reach a road, and what to
draw for the gap.

A verified arrival point (gate, parking, pier) was chosen to sit on a road, so
a distant snap there means bad data and the route is rejected. An attraction
pin without an arrival point (a waterfall, a park interior, a beach) usually
sits off-road, so the road part is kept and the gap between the road end and
the pin is returned as a dashed "last stretch" segment instead of discarding
the whole road route.
"""

from __future__ import annotations

from math import asin, cos, radians, sin, sqrt
from typing import Protocol

from app.features.routes.polyline import decode_polyline5, encode_polyline5
from app.features.routes.schemas import RouteSegment
from app.integrations.osrm.client import (
    MAX_PORT_WAYPOINT_SNAP_METERS,
    MAX_PREVIEW_WAYPOINT_SNAP_METERS,
)
from app.integrations.osrm.schemas import OSRMRouteResult

# Farther than this, an unverified pin is more likely wrong than off-road.
MAX_ATTRACTION_WAYPOINT_SNAP_METERS = 2000.0
# Gaps up to this size are normal driveway/curb offsets and are not drawn.
LAST_STRETCH_NOTICE_METERS = MAX_PREVIEW_WAYPOINT_SNAP_METERS


class SnapStop(Protocol):
    name: str
    lat: float
    lng: float
    is_origin: bool
    coordinate_basis: str
    is_port: bool


def snap_limit_meters(stop: SnapStop) -> float:
    if getattr(stop, "is_port", False):
        return MAX_PORT_WAYPOINT_SNAP_METERS
    if getattr(stop, "coordinate_basis", "attraction") == "verified_arrival":
        return MAX_PREVIEW_WAYPOINT_SNAP_METERS
    # Attraction pins and the traveler's own GPS position may be off-road.
    return MAX_ATTRACTION_WAYPOINT_SNAP_METERS


def snap_limits(stops: list[SnapStop]) -> list[float]:
    return [snap_limit_meters(stop) for stop in stops]


def last_stretch_gaps(
    stops: list[SnapStop], result: OSRMRouteResult,
) -> list[tuple[int, tuple[float, float], float]]:
    """(stop index, road point (lat, lng), gap meters) for each far snap."""
    gaps = []
    for index, (stop, snap) in enumerate(zip(stops, result.waypoint_snaps)):
        if snap is None:
            continue
        lat, lng, meters = snap
        if getattr(stop, "is_port", False) or meters <= LAST_STRETCH_NOTICE_METERS:
            continue
        gaps.append((index, (lat, lng), meters))
    return gaps


def last_stretch_segment(
    stop: SnapStop, road_point: tuple[float, float], *, order: int,
) -> RouteSegment:
    """Dashed connector between the road end and an off-road stop."""
    if stop.is_origin:
        points = [(stop.lat, stop.lng), road_point]
        from_name, to_name = stop.name, f"Road near {stop.name}"
    else:
        points = [road_point, (stop.lat, stop.lng)]
        from_name, to_name = f"Road near {stop.name}", stop.name
    return RouteSegment(
        order=order,
        mode="road",
        from_name=from_name,
        to_name=to_name,
        polyline=encode_polyline5(points),
        is_estimated=True,
    )


def last_stretch_warning(stop: SnapStop, meters: float) -> str:
    distance = (
        f"{meters / 1000:.1f} km" if meters >= 1000 else f"{round(meters / 10) * 10:.0f} m"
    )
    if stop.is_origin:
        return (
            f"Your starting point is about {distance} from the nearest mapped road; "
            "the dashed line shows that first stretch."
        )
    return (
        f"The road ends about {distance} from {stop.name}; the last stretch is on "
        "foot or by trail (dashed). Exact gate or parking point not yet verified."
    )


def stop_access_points(stop: SnapStop) -> list[tuple[float, float]] | None:
    """Return decoded admin custom access-trail points for [stop], or None."""
    encoded = getattr(stop, "access_trail_polyline", None)
    if not encoded:
        return None
    try:
        points = decode_polyline5(encoded)
    except ValueError:
        return None
    return points if len(points) >= 2 else None


def access_trail_segment(
    stop: SnapStop,
    *,
    order: int,
    exiting: bool = False,
    road_point: tuple[float, float] | None = None,
) -> RouteSegment | None:
    """Mapped last-mile access road/trail connecting a road gate to the stop."""
    points = stop_access_points(stop)
    if not points:
        return None
    coords = list(points)
    if exiting:
        coords.reverse()
        if road_point is not None and haversine_meters(coords[-1], road_point) > 30.0:
            coords.append(road_point)
        from_name, to_name = stop.name, f"{stop.name} Road Entry"
    else:
        if road_point is not None and haversine_meters(road_point, coords[0]) > 30.0:
            coords.insert(0, road_point)
        from_name, to_name = f"{stop.name} Road Entry", stop.name
    return RouteSegment(
        order=order,
        mode="road",
        from_name=from_name,
        to_name=to_name,
        polyline=encode_polyline5(coords),
        is_estimated=False,
    )


def build_road_run_segments(
    stops: list[SnapStop],
    osrm_result: OSRMRouteResult,
    *,
    start_order: int = 1,
    emit_when_plain: bool = False,
) -> tuple[list[RouteSegment], list[str]]:
    """Build road run segments + warnings combining OSRM geometry, admin trails, and gaps."""
    if not osrm_result.polyline:
        return [], []

    raw_gaps = last_stretch_gaps(stops, osrm_result)
    gap_points = {index: road_point for index, road_point, _ in raw_gaps}
    unmapped_gaps = [
        (index, road_point, meters)
        for index, road_point, meters in raw_gaps
        if stop_access_points(stops[index]) is None
    ]
    unmapped_by_index = {index: road_point for index, road_point, _ in unmapped_gaps}
    warnings = [
        last_stretch_warning(stops[index], meters)
        for index, _, meters in unmapped_gaps
    ]
    has_access_trails = any(stop_access_points(stop) is not None for stop in stops)

    if not emit_when_plain and not unmapped_by_index and not has_access_trails:
        return [], warnings

    segments: list[RouteSegment] = []

    def next_order() -> int:
        return start_order + len(segments)

    if not stops[0].is_origin and stop_access_points(stops[0]) is not None:
        seg = access_trail_segment(
            stops[0],
            order=next_order(),
            exiting=True,
            road_point=gap_points.get(0),
        )
        if seg is not None:
            segments.append(seg)
    elif 0 in unmapped_by_index:
        segments.append(
            last_stretch_segment(stops[0], unmapped_by_index[0], order=next_order())
        )

    segments.append(
        RouteSegment(
            order=next_order(),
            mode="road",
            from_name=stops[0].name,
            to_name=stops[-1].name,
            polyline=osrm_result.polyline,
            is_estimated=False,
        )
    )

    for index in range(1, len(stops)):
        if stop_access_points(stops[index]) is not None:
            seg = access_trail_segment(
                stops[index],
                order=next_order(),
                exiting=False,
                road_point=gap_points.get(index),
            )
            if seg is not None:
                segments.append(seg)
        elif index in unmapped_by_index:
            segments.append(
                last_stretch_segment(
                    stops[index],
                    unmapped_by_index[index],
                    order=next_order(),
                )
            )

    return segments, warnings


def haversine_meters(a: tuple[float, float], b: tuple[float, float]) -> float:
    lat1, lng1 = map(radians, a)
    lat2, lng2 = map(radians, b)
    h = sin((lat2 - lat1) / 2) ** 2 + cos(lat1) * cos(lat2) * sin((lng2 - lng1) / 2) ** 2
    return 2 * 6_371_000 * asin(sqrt(h))

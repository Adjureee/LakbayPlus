"""Off-road attraction pins keep their road route plus a dashed last stretch."""

import pytest

from app.features.routes.polyline import decode_polyline5, encode_polyline5
from app.features.routes.service import RoutePlanStop, _osrm_response
from app.features.routes.snap_policy import (
    MAX_ATTRACTION_WAYPOINT_SNAP_METERS,
    snap_limit_meters,
)
from app.integrations.osrm.client import (
    MAX_PORT_WAYPOINT_SNAP_METERS,
    MAX_PREVIEW_WAYPOINT_SNAP_METERS,
    _require_near_route_waypoints,
    _waypoint_snaps,
)
from app.integrations.osrm.errors import OSRMRouteNotFoundError
from app.integrations.osrm.schemas import OSRMLeg, OSRMRouteResult

ORIGIN = RoutePlanStop(
    destination_id=None, name="Panabo", lat=7.30, lng=125.68,
    is_origin=True, coordinate_basis="origin",
)
FALLS = RoutePlanStop(
    destination_id=8, name="Tagbibinta Falls", lat=7.3476, lng=126.1514,
)
GATE = RoutePlanStop(
    destination_id=8, name="Tagbibinta Gate", lat=7.3195, lng=126.1438,
    coordinate_basis="verified_arrival",
)


def _body(snap_meters: list[float]) -> dict:
    return {
        "waypoints": [
            {"location": [125.0 + i, 7.0 + i], "distance": meters}
            for i, meters in enumerate(snap_meters)
        ],
    }


def test_snap_limits_by_coordinate_basis():
    assert snap_limit_meters(GATE) == MAX_PREVIEW_WAYPOINT_SNAP_METERS
    assert snap_limit_meters(FALLS) == MAX_ATTRACTION_WAYPOINT_SNAP_METERS
    assert snap_limit_meters(ORIGIN) == MAX_ATTRACTION_WAYPOINT_SNAP_METERS
    port = RoutePlanStop(destination_id=None, name="Sasa", lat=7.1, lng=125.6, is_port=True)
    assert snap_limit_meters(port) == MAX_PORT_WAYPOINT_SNAP_METERS


def test_attraction_snap_of_600m_is_allowed_but_gate_is_not():
    limits = [snap_limit_meters(ORIGIN), snap_limit_meters(FALLS)]
    _require_near_route_waypoints(_body([20, 600]), 2, max_snap_meters=limits)

    gate_limits = [snap_limit_meters(ORIGIN), snap_limit_meters(GATE)]
    with pytest.raises(OSRMRouteNotFoundError):
        _require_near_route_waypoints(_body([20, 600]), 2, max_snap_meters=gate_limits)


def test_attraction_snap_beyond_2km_is_rejected():
    limits = [snap_limit_meters(ORIGIN), snap_limit_meters(FALLS)]
    with pytest.raises(OSRMRouteNotFoundError):
        _require_near_route_waypoints(_body([20, 2500]), 2, max_snap_meters=limits)


def test_waypoint_snaps_reads_lat_lng_and_distance():
    assert _waypoint_snaps(_body([20, 600])) == [(7.0, 125.0, 20.0), (8.0, 126.0, 600.0)]
    assert _waypoint_snaps({"waypoints": [{"distance": 5}]}) == [None]


def _result(snaps) -> OSRMRouteResult:
    road = encode_polyline5([(7.30, 125.68), (7.33, 126.0), (7.343, 126.149)])
    return OSRMRouteResult(
        total_distance_meters=90_000,
        total_duration_seconds=7200,
        legs=[OSRMLeg(distance_meters=90_000, duration_seconds=7200)],
        polyline=road,
        waypoint_snaps=snaps,
    )


def test_far_attraction_snap_adds_dashed_last_stretch_and_warning():
    response = _osrm_response(
        travel_mode="driving",
        stops=[ORIGIN, FALLS],
        osrm_result=_result([(7.30, 125.68, 10.0), (7.343, 126.149, 560.0)]),
    )

    assert response.is_estimated is False
    assert response.polyline  # the road itself is still drawn solid
    assert [(s.mode, s.is_estimated) for s in response.segments] == [
        ("road", False),
        ("road", True),
    ]
    dashed = decode_polyline5(response.segments[1].polyline)
    assert dashed[0] == (7.343, 126.149)
    assert dashed[-1] == (FALLS.lat, FALLS.lng)
    assert any("560 m from Tagbibinta Falls" in w for w in response.warnings)


def test_near_snaps_keep_plain_polyline_without_segments():
    response = _osrm_response(
        travel_mode="driving",
        stops=[ORIGIN, FALLS],
        osrm_result=_result([(7.30, 125.68, 10.0), (7.3476, 126.1514, 40.0)]),
    )
    assert response.segments == []
    assert not any("road ends" in w for w in response.warnings)

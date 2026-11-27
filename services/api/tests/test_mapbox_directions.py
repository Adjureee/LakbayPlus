import asyncio
from types import SimpleNamespace

import httpx
import pytest

from app.features.routes.schemas import RouteCoordinate
from app.integrations.mapbox_directions.client import (
    ChainedRoutingClient,
    MapboxDirectionsClient,
)
from app.integrations.osrm import client as osrm_module
from app.integrations.osrm.client import OSRMClient
from app.integrations.osrm.errors import OSRMClientError, OSRMConfigurationError
from app.integrations.osrm.schemas import OSRMRouteResult


COORDS = [RouteCoordinate(lat=7.0731, lng=125.6128), RouteCoordinate(lat=7.1854, lng=125.4169)]
ROUTE_BODY = {
    "code": "Ok",
    "routes": [{
        "distance": 32000, "duration": 2700, "geometry": "abc",
        "legs": [{"distance": 32000, "duration": 2700, "steps": [
            {"distance": 32000, "duration": 2700, "mode": "driving", "name": "Calinan Road",
             "maneuver": {"type": "depart", "location": [125.6128, 7.0731]}},
        ]}],
    }],
    "waypoints": [{"distance": 3.2}, {"distance": 12.0}],
}


def mapbox_settings(**overrides):
    values = {
        "mapbox_directions_token": "sk.test-token",
        "mapbox_directions_base_url": "https://api.mapbox.test",
        "mapbox_directions_profile_driving": "driving-traffic",
        "mapbox_directions_timeout_seconds": 5,
        "osrm_base_url": "https://osrm.example.test",
        "osrm_profile_driving": "driving",
        "osrm_request_timeout_seconds": 5,
    }
    values.update(overrides)
    return SimpleNamespace(**values)


def mock_http(monkeypatch, handler):
    real_async_client = httpx.AsyncClient
    monkeypatch.setattr(
        osrm_module.httpx,
        "AsyncClient",
        lambda **kwargs: real_async_client(transport=httpx.MockTransport(handler), **kwargs),
    )


def test_mapbox_route_uses_directions_api_with_token(monkeypatch) -> None:
    seen = {}

    def handler(request: httpx.Request) -> httpx.Response:
        seen["url"] = request.url
        return httpx.Response(200, json=ROUTE_BODY)

    mock_http(monkeypatch, handler)
    result = asyncio.run(MapboxDirectionsClient(mapbox_settings()).preview_route(
        travel_mode="driving", coordinates=COORDS,
    ))

    assert seen["url"].host == "api.mapbox.test"
    assert seen["url"].path.startswith("/directions/v5/mapbox/driving-traffic/125.612800,7.073100;")
    assert seen["url"].params["access_token"] == "sk.test-token"
    assert seen["url"].params["overview"] == "full"
    assert result.provider == "mapbox"
    assert result.polyline == "abc"
    assert result.legs[0].steps[0].road_name == "Calinan Road"


def test_mapbox_ordering_uses_plain_driving_profile(monkeypatch) -> None:
    paths = []

    def handler(request: httpx.Request) -> httpx.Response:
        paths.append(request.url.path)
        if request.url.path.startswith("/directions-matrix/"):
            return httpx.Response(200, json={
                "code": "Ok",
                "durations": [[0, 10], [10, 0]],
                "distances": [[0, 100], [100, 0]],
            })
        return httpx.Response(200, json={
            "code": "Ok",
            "trips": [{"distance": 1, "duration": 1, "legs": [{"distance": 1, "duration": 1}]}],
            "waypoints": [{"waypoint_index": 0, "trips_index": 0},
                          {"waypoint_index": 1, "trips_index": 0}],
        })

    mock_http(monkeypatch, handler)
    client = MapboxDirectionsClient(mapbox_settings())
    asyncio.run(client.matrix(travel_mode="driving", coordinates=COORDS))
    asyncio.run(client.optimize_route(
        travel_mode="driving", coordinates=COORDS, roundtrip=False, preserve_first=True,
    ))

    assert paths[0].startswith("/directions-matrix/v1/mapbox/driving/")
    assert paths[1].startswith("/optimization/v1/mapbox/driving/")


def test_mapbox_rejects_far_snapped_waypoints(monkeypatch) -> None:
    body = {**ROUTE_BODY, "waypoints": [{"distance": 3.2}, {"distance": 900.0}]}
    mock_http(monkeypatch, lambda request: httpx.Response(200, json=body))

    with pytest.raises(OSRMClientError, match="too far"):
        asyncio.run(MapboxDirectionsClient(mapbox_settings()).preview_route(
            travel_mode="driving", coordinates=COORDS,
        ))


def test_mapbox_optimization_limit_is_checked_before_request() -> None:
    client = MapboxDirectionsClient(mapbox_settings())
    many = [RouteCoordinate(lat=7.0 + i / 100, lng=125.5) for i in range(13)]

    with pytest.raises(OSRMConfigurationError, match="at most 12"):
        asyncio.run(client.optimize_route(
            travel_mode="driving", coordinates=many, roundtrip=False, preserve_first=True,
        ))


def test_mapbox_requires_token() -> None:
    with pytest.raises(OSRMConfigurationError, match="MAPBOX_DIRECTIONS_TOKEN"):
        MapboxDirectionsClient(mapbox_settings(mapbox_directions_token=None))


class _FakeRouter(OSRMClient):
    def __init__(self, name, outcome):
        self.provider_name = name
        self.outcome = outcome
        self.calls = 0

    async def preview_route(self, **kwargs):
        self.calls += 1
        if isinstance(self.outcome, Exception):
            raise self.outcome
        return self.outcome


def test_chain_falls_back_to_osrm_when_mapbox_fails() -> None:
    osrm_result = OSRMRouteResult(
        total_distance_meters=1, total_duration_seconds=1, legs=[], provider="osrm",
    )
    mapbox = _FakeRouter("mapbox", OSRMClientError("Mapbox quota exceeded."))
    osrm = _FakeRouter("osrm", osrm_result)
    chain = ChainedRoutingClient([mapbox, osrm], mapbox_settings())

    result = asyncio.run(chain.preview_route(travel_mode="driving", coordinates=COORDS))

    assert result is osrm_result
    assert (mapbox.calls, osrm.calls) == (1, 1)


def test_chain_raises_last_error_when_every_router_fails() -> None:
    chain = ChainedRoutingClient(
        [_FakeRouter("mapbox", OSRMClientError("a")), _FakeRouter("osrm", OSRMClientError("b"))],
        mapbox_settings(),
    )

    with pytest.raises(OSRMClientError, match="b"):
        asyncio.run(chain.preview_route(travel_mode="driving", coordinates=COORDS))


def test_get_osrm_client_prefers_mapbox_when_token_set(monkeypatch) -> None:
    monkeypatch.setattr(osrm_module, "get_settings", lambda: mapbox_settings())
    client = osrm_module.get_osrm_client()
    assert isinstance(client, ChainedRoutingClient)
    assert [item.provider_name for item in client.clients] == ["mapbox", "osrm"]

    monkeypatch.setattr(
        osrm_module, "get_settings", lambda: mapbox_settings(mapbox_directions_token=None),
    )
    assert type(osrm_module.get_osrm_client()) is OSRMClient


def test_mapbox_cycling_uses_cycling_profile_across_endpoints(monkeypatch) -> None:
    paths = []

    def handler(request: httpx.Request) -> httpx.Response:
        paths.append(request.url.path)
        if request.url.path.startswith("/directions-matrix/"):
            return httpx.Response(200, json={
                "code": "Ok",
                "durations": [[0, 600], [600, 0]],
                "distances": [[0, 2500], [2500, 0]],
            })
        if request.url.path.startswith("/optimization/"):
            return httpx.Response(200, json={
                "code": "Ok",
                "trips": [{"distance": 2500, "duration": 600, "legs": [{"distance": 2500, "duration": 600}]}],
                "waypoints": [{"waypoint_index": 0, "trips_index": 0},
                              {"waypoint_index": 1, "trips_index": 0}],
            })
        return httpx.Response(200, json=ROUTE_BODY)

    mock_http(monkeypatch, handler)
    client = MapboxDirectionsClient(mapbox_settings())
    preview = asyncio.run(client.preview_route(travel_mode="cycling", coordinates=COORDS))
    asyncio.run(client.matrix(travel_mode="cycling", coordinates=COORDS))
    asyncio.run(client.optimize_route(
        travel_mode="cycling", coordinates=COORDS, roundtrip=False, preserve_first=True,
    ))

    assert preview.provider == "mapbox"
    assert paths[0].startswith("/directions/v5/mapbox/cycling/")
    assert paths[1].startswith("/directions-matrix/v1/mapbox/cycling/")
    assert paths[2].startswith("/optimization/v1/mapbox/cycling/")


def test_osrm_rejects_cycling_so_fallback_is_estimated() -> None:
    osrm = OSRMClient(mapbox_settings())
    with pytest.raises(OSRMConfigurationError, match="cycling"):
        asyncio.run(osrm.preview_route(travel_mode="cycling", coordinates=COORDS))


def test_route_service_cycling_osrm_fallback_returns_estimated_never_road_time() -> None:
    from app.features.routes.schemas import RoutePreviewRequest
    from app.features.routes.service import RoutePlanStop, RouteService

    class _NoSeaLinks:
        async def list_active_links(self):
            return []

    service = RouteService.__new__(RouteService)
    service.osrm_client = OSRMClient(mapbox_settings())
    service.google_routes_client = None
    service.sea_links = _NoSeaLinks()

    stops = [
        RoutePlanStop(destination_id=1, name="Davao City", lat=7.0731, lng=125.6128),
        RoutePlanStop(destination_id=2, name="Calinan", lat=7.1854, lng=125.4169),
    ]
    req = RoutePreviewRequest(destination_ids=[1, 2], travel_mode="cycling")
    result = asyncio.run(service._preview_stops(req, stops))

    assert result.travel_mode == "cycling"
    assert result.is_estimated is True
    assert result.route_provider == "haversine"
    assert all(leg.is_estimated for leg in result.legs)
    assert result.traffic is None

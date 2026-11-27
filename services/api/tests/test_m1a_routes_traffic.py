import httpx
from types import SimpleNamespace

from app.core.config import Settings, get_settings
from app.features.routes.polyline import encode_polyline5
from app.integrations.google_routes.client import get_google_routes_client
from app.integrations.mapbox_directions.client import (
    MAPBOX_DIRECTIONS_MAX_COORDINATES,
    MapboxDirectionsClient,
)
from app.integrations.osrm import client as osrm_module
from app.integrations.osrm.client import OSRMClient, get_osrm_client
from app.integrations.osrm.errors import OSRMRouteNotFoundError
from app.integrations.osrm.schemas import OSRMLeg, OSRMMatrixResult, OSRMRouteResult
from tests.test_phase6_routes import (
    DESTINATION_A,
    DESTINATION_B,
    DESTINATION_C,
    FakeOSRMClient,
    admin_headers,
    create_destination,
    create_route_destinations,
    user_headers,
)
from tests.test_sea_routing import samal_destination, seed_sea_links


def _mapbox_settings(**overrides):
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


def _mock_osrm_http(monkeypatch, handler):
    real_async_client = httpx.AsyncClient
    monkeypatch.setattr(
        osrm_module.httpx,
        "AsyncClient",
        lambda **kwargs: real_async_client(
            transport=httpx.MockTransport(handler), **kwargs
        ),
    )


def _set_route_limit(monkeypatch, value: str) -> None:
    monkeypatch.setenv("ROUTE_MAX_DESTINATIONS", value)
    get_settings.cache_clear()


def test_default_settings_route_max_destinations_is_50() -> None:
    settings = Settings(_env_file=None)
    assert settings.route_max_destinations == 50
    assert settings.route_chunk_max_coordinates == 25


def test_mapbox_driving_traffic_requests_annotations_and_parses_congestion(
    client, monkeypatch,
) -> None:
    destination_a, destination_b, _ = create_route_destinations(client)
    seen_requests: list[httpx.Request] = []
    poly = encode_polyline5(
        [
            (destination_a["lat"], destination_a["lng"]),
            (7.08, 125.612),
            (destination_b["lat"], destination_b["lng"]),
        ]
    )

    def handler(request: httpx.Request) -> httpx.Response:
        seen_requests.append(request)
        return httpx.Response(
            200,
            json={
                "code": "Ok",
                "routes": [
                    {
                        "distance": 12000,
                        "duration": 1380,
                        "duration_typical": 1200,
                        "geometry": poly,
                        "legs": [
                            {
                                "distance": 12000,
                                "duration": 1380,
                                "duration_typical": 1200,
                                "annotation": {
                                    "congestion": ["low", "heavy"],
                                    "distance": [5000, 7000],
                                    "duration": [500, 880],
                                },
                                "steps": [],
                            }
                        ],
                    }
                ],
                "waypoints": [{"distance": 4.0}, {"distance": 5.0}],
            },
        )

    _mock_osrm_http(monkeypatch, handler)
    mb_client = MapboxDirectionsClient(_mapbox_settings())
    client.app.dependency_overrides[get_osrm_client] = lambda: mb_client
    client.app.dependency_overrides[get_google_routes_client] = lambda: None

    resp = client.post(
        "/api/v1/routes/preview",
        headers=user_headers(client),
        json={
            "destination_ids": [
                destination_a["destination_id"],
                destination_b["destination_id"],
            ],
            "travel_mode": "driving",
            "use_live_traffic": True,
        },
    )

    assert resp.status_code == 200, resp.text
    assert seen_requests[0].url.path.startswith("/directions/v5/mapbox/driving-traffic/")
    assert (
        seen_requests[0].url.params["annotations"]
        == "congestion,duration,distance,speed"
    )
    body = resp.json()
    assert body["route_provider"] == "mapbox"
    assert body["traffic_info"]["status"] == "live"
    assert body["traffic_info"]["provider"] == "mapbox"
    assert body["traffic_info"]["delay_seconds"] == 180
    levels = [seg["level"] for seg in body["traffic_info"]["congestion_segments"]]
    assert levels == ["light", "heavy"]
    assert all(seg["polyline"] for seg in body["traffic_info"]["congestion_segments"])
    assert body["traffic"]["status"] == "live"
    assert body["traffic"]["delay_seconds"] == 180


def test_mapbox_unknown_annotations_report_limited_coverage_without_fabricating(
    client, monkeypatch,
) -> None:
    destination_a, destination_b, _ = create_route_destinations(client)

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(
            200,
            json={
                "code": "Ok",
                "routes": [
                    {
                        "distance": 12000,
                        "duration": 1500,
                        "geometry": "abc",
                        "legs": [
                            {
                                "distance": 12000,
                                "duration": 1500,
                                "annotation": {
                                    "congestion": ["unknown", "unknown"],
                                },
                                "steps": [],
                            }
                        ],
                    }
                ],
                "waypoints": [{"distance": 4.0}, {"distance": 5.0}],
            },
        )

    _mock_osrm_http(monkeypatch, handler)
    client.app.dependency_overrides[get_osrm_client] = (
        lambda: MapboxDirectionsClient(_mapbox_settings())
    )
    client.app.dependency_overrides[get_google_routes_client] = lambda: None

    resp = client.post(
        "/api/v1/routes/preview",
        headers=user_headers(client),
        json={
            "destination_ids": [
                destination_a["destination_id"],
                destination_b["destination_id"],
            ],
            "travel_mode": "driving",
            "use_live_traffic": True,
        },
    )

    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["traffic"] is None
    assert body["traffic_info"]["status"] == "limited_coverage"
    assert body["traffic_info"]["provider"] == "mapbox"
    assert body["traffic_info"]["delay_seconds"] is None
    assert body["traffic_info"]["congestion_segments"] == []


def test_no_live_traffic_provider_reports_unavailable_no_provider(client) -> None:
    destination_a, destination_b, _ = create_route_destinations(client)
    fake_osrm = FakeOSRMClient(
        preview_result=OSRMRouteResult(
            total_distance_meters=12000,
            total_duration_seconds=1500,
            legs=[OSRMLeg(distance_meters=12000, duration_seconds=1500)],
            provider="osrm",
        )
    )
    client.app.dependency_overrides[get_osrm_client] = lambda: fake_osrm
    client.app.dependency_overrides[get_google_routes_client] = lambda: None

    resp = client.post(
        "/api/v1/routes/preview",
        headers=user_headers(client),
        json={
            "destination_ids": [
                destination_a["destination_id"],
                destination_b["destination_id"],
            ],
            "travel_mode": "driving",
            "use_live_traffic": True,
        },
    )

    assert resp.status_code == 200
    body = resp.json()
    assert body["traffic"] is None
    assert body["traffic_info"]["status"] == "unavailable_no_provider"
    assert body["traffic_info"]["provider"] is None


def test_use_live_traffic_false_reports_disabled_and_uses_plain_driving(
    client, monkeypatch,
) -> None:
    destination_a, destination_b, _ = create_route_destinations(client)
    seen_paths: list[str] = []

    def handler(request: httpx.Request) -> httpx.Response:
        seen_paths.append(request.url.path)
        return httpx.Response(
            200,
            json={
                "code": "Ok",
                "routes": [
                    {
                        "distance": 12000,
                        "duration": 1500,
                        "geometry": "abc",
                        "legs": [{"distance": 12000, "duration": 1500, "steps": []}],
                    }
                ],
                "waypoints": [{"distance": 2.0}, {"distance": 2.0}],
            },
        )

    _mock_osrm_http(monkeypatch, handler)
    client.app.dependency_overrides[get_osrm_client] = (
        lambda: MapboxDirectionsClient(_mapbox_settings())
    )
    client.app.dependency_overrides[get_google_routes_client] = lambda: None

    resp = client.post(
        "/api/v1/routes/preview",
        headers=user_headers(client),
        json={
            "destination_ids": [
                destination_a["destination_id"],
                destination_b["destination_id"],
            ],
            "travel_mode": "driving",
            "use_live_traffic": False,
        },
    )

    assert resp.status_code == 200
    assert seen_paths[0].startswith("/directions/v5/mapbox/driving/")
    body = resp.json()
    assert body["traffic"] is None
    assert body["traffic_info"]["status"] == "disabled"


def test_route_preview_allows_non_consecutive_hub_revisits_and_rejects_consecutive(
    client,
) -> None:
    a, b, c = create_route_destinations(client)
    fake_osrm = FakeOSRMClient(
        preview_result=OSRMRouteResult(
            total_distance_meters=30000,
            total_duration_seconds=2700,
            legs=[
                OSRMLeg(distance_meters=10000, duration_seconds=900),
                OSRMLeg(distance_meters=10000, duration_seconds=900),
                OSRMLeg(distance_meters=10000, duration_seconds=900),
            ],
        )
    )
    client.app.dependency_overrides[get_osrm_client] = lambda: fake_osrm
    headers = user_headers(client)

    ok_resp = client.post(
        "/api/v1/routes/preview",
        headers=headers,
        json={
            "destination_ids": [
                a["destination_id"],
                b["destination_id"],
                c["destination_id"],
                a["destination_id"],
            ],
            "travel_mode": "driving",
        },
    )
    assert ok_resp.status_code == 200, ok_resp.text
    ok_body = ok_resp.json()
    assert len(ok_body["stops"]) == 4
    assert len(ok_body["legs"]) == 3
    assert [s["destination_id"] for s in ok_body["stops"]] == [
        a["destination_id"],
        b["destination_id"],
        c["destination_id"],
        a["destination_id"],
    ]

    dup_resp = client.post(
        "/api/v1/routes/preview",
        headers=headers,
        json={
            "destination_ids": [a["destination_id"], a["destination_id"]],
            "travel_mode": "driving",
        },
    )
    assert dup_resp.status_code == 422


def test_route_preview_skips_inactive_destination_when_two_valid_stops_remain(
    client,
) -> None:
    a, b, _ = create_route_destinations(client)
    fake_osrm = FakeOSRMClient(
        preview_result=OSRMRouteResult(
            total_distance_meters=10000,
            total_duration_seconds=900,
            legs=[OSRMLeg(distance_meters=10000, duration_seconds=900)],
        )
    )
    client.app.dependency_overrides[get_osrm_client] = lambda: fake_osrm
    headers = user_headers(client)

    ok_resp = client.post(
        "/api/v1/routes/preview",
        headers=headers,
        json={
            "destination_ids": [a["destination_id"], 99999, b["destination_id"]],
            "travel_mode": "driving",
        },
    )
    assert ok_resp.status_code == 200, ok_resp.text
    body = ok_resp.json()
    assert [s["destination_id"] for s in body["stops"]] == [
        a["destination_id"],
        b["destination_id"],
    ]
    assert body["skipped_destination_ids"] == [99999]
    assert any("99999" in w for w in body["warnings"])

    fail_resp = client.post(
        "/api/v1/routes/preview",
        headers=headers,
        json={
            "destination_ids": [a["destination_id"], 99999],
            "travel_mode": "driving",
        },
    )
    assert fail_resp.status_code == 404
    assert fail_resp.json()["error"]["details"]["destination_ids"] == [99999]


def test_route_preview_chunks_more_than_25_coordinates_for_14_day_trip(
    client, monkeypatch,
) -> None:
    _set_route_limit(monkeypatch, "50")
    try:
        headers_admin = admin_headers(client)
        created_ids: list[int] = []
        for idx in range(28):
            dest = create_destination(
                client,
                headers_admin,
                {
                    **DESTINATION_A,
                    "name": f"Stop {idx + 1}",
                    "lat": 7.05 + idx * 0.004,
                    "lng": 125.55 + idx * 0.004,
                },
            )
            created_ids.append(dest["destination_id"])

        chunk_coord_counts: list[int] = []

        class _ChunkCheckingRouter(OSRMClient):
            provider_name = "mapbox"

            def __init__(self):
                pass

            async def preview_route(self, *, travel_mode, coordinates):
                chunk_coord_counts.append(len(coordinates))
                assert len(coordinates) <= MAPBOX_DIRECTIONS_MAX_COORDINATES
                pts = [(c.lat, c.lng) for c in coordinates]
                return OSRMRouteResult(
                    total_distance_meters=1000.0 * (len(coordinates) - 1),
                    total_duration_seconds=300.0 * (len(coordinates) - 1),
                    legs=[
                        OSRMLeg(distance_meters=1000.0, duration_seconds=300.0)
                        for _ in coordinates[1:]
                    ],
                    polyline=encode_polyline5(pts),
                    provider="mapbox",
                )

        client.app.dependency_overrides[get_osrm_client] = _ChunkCheckingRouter
        resp = client.post(
            "/api/v1/routes/preview",
            headers=user_headers(client),
            json={
                "destination_ids": created_ids,
                "travel_mode": "driving",
                "origin": {"label": "Hotel", "lat": 7.04, "lng": 125.54},
                "return_to_origin": True,
            },
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert chunk_coord_counts == [25, 6]
        assert len(body["stops"]) == 30
        assert len(body["legs"]) == 29
        assert body["is_estimated"] is False
        assert body["polyline"]
    finally:
        monkeypatch.undo()
        get_settings.cache_clear()


def test_route_preview_isolates_single_bad_snap_per_leg_without_dropping_other_legs(
    client, monkeypatch,
) -> None:
    _set_route_limit(monkeypatch, "50")
    try:
        headers_admin = admin_headers(client)
        stops = [
            create_destination(
                client,
                headers_admin,
                {
                    **DESTINATION_A,
                    "name": f"SnapStop {idx + 1}",
                    "lat": 7.05 + idx * 0.01,
                    "lng": 125.58 + idx * 0.01,
                },
            )
            for idx in range(5)
        ]
        bad_label = "SnapStop 3"

        class _SelectiveSnapFailRouter(OSRMClient):
            provider_name = "mapbox"

            def __init__(self):
                pass

            async def preview_route(self, *, travel_mode, coordinates):
                if any(c.label == bad_label for c in coordinates):
                    raise OSRMRouteNotFoundError(
                        "OSRM snapped a route waypoint too far from the requested point."
                    )
                pts = [(c.lat, c.lng) for c in coordinates]
                return OSRMRouteResult(
                    total_distance_meters=1500.0 * (len(coordinates) - 1),
                    total_duration_seconds=300.0 * (len(coordinates) - 1),
                    legs=[
                        OSRMLeg(distance_meters=1500.0, duration_seconds=300.0)
                        for _ in coordinates[1:]
                    ],
                    polyline=encode_polyline5(pts),
                    provider="mapbox",
                )

        client.app.dependency_overrides[get_osrm_client] = _SelectiveSnapFailRouter
        resp = client.post(
            "/api/v1/routes/preview",
            headers=user_headers(client),
            json={
                "destination_ids": [s["destination_id"] for s in stops],
                "travel_mode": "driving",
            },
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["is_estimated"] is True
        assert body["polyline"] is None
        assert body["route_provider"] == "mapbox"
        assert [seg["mode"] for seg in body["segments"]] == [
            "road",
            "unrouted",
            "unrouted",
            "road",
        ]
        assert [seg["is_estimated"] for seg in body["segments"]] == [
            False,
            True,
            True,
            False,
        ]
        assert all(seg["polyline"] for seg in body["segments"])
        assert body["segments"][1]["reason"] == "snap_or_road_unavailable"
    finally:
        monkeypatch.undo()
        get_settings.cache_clear()


def test_route_optimize_15_stops_exceeding_mapbox_12_limit_uses_chunked_road_preview(
    client, monkeypatch,
) -> None:
    _set_route_limit(monkeypatch, "50")
    try:
        headers_admin = admin_headers(client)
        stops = [
            create_destination(
                client,
                headers_admin,
                {
                    **DESTINATION_A,
                    "name": f"OptStop {idx + 1}",
                    "lat": 7.05 + idx * 0.008,
                    "lng": 125.56 + idx * 0.008,
                },
            )
            for idx in range(15)
        ]

        def handler(request: httpx.Request) -> httpx.Response:
            if request.url.path.startswith("/directions-matrix/"):
                n = 15
                return httpx.Response(
                    200,
                    json={
                        "code": "Ok",
                        "durations": [
                            [0 if i == j else abs(i - j) * 120 for j in range(n)]
                            for i in range(n)
                        ],
                        "distances": [
                            [0 if i == j else abs(i - j) * 1000 for j in range(n)]
                            for i in range(n)
                        ],
                    },
                )
            assert request.url.path.startswith("/directions/v5/mapbox/")
            coords_part = request.url.path.split("/")[-1]
            coord_pairs = coords_part.split(";")
            assert len(coord_pairs) <= MAPBOX_DIRECTIONS_MAX_COORDINATES
            pts = [
                (float(pair.split(",")[1]), float(pair.split(",")[0]))
                for pair in coord_pairs
            ]
            return httpx.Response(
                200,
                json={
                    "code": "Ok",
                    "routes": [
                        {
                            "distance": 1000 * (len(pts) - 1),
                            "duration": 180 * (len(pts) - 1),
                            "geometry": encode_polyline5(pts),
                            "legs": [
                                {"distance": 1000, "duration": 180, "steps": []}
                                for _ in pts[1:]
                            ],
                        }
                    ],
                    "waypoints": [{"distance": 3.0} for _ in pts],
                },
            )

        _mock_osrm_http(monkeypatch, handler)
        client.app.dependency_overrides[get_osrm_client] = (
            lambda: MapboxDirectionsClient(_mapbox_settings())
        )
        resp = client.post(
            "/api/v1/routes/optimize",
            headers=user_headers(client),
            json={
                "destination_ids": [s["destination_id"] for s in stops],
                "travel_mode": "driving",
            },
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["route_provider"] == "mapbox"
        assert body["is_estimated"] is False
        assert body["order_method"] == "nearest_neighbor_2opt"
        assert len(body["legs"]) == 14
        assert body["polyline"]
    finally:
        monkeypatch.undo()
        get_settings.cache_clear()


def test_route_plan_15_stops_5_days_with_revisit_and_samal_crossing(
    client, monkeypatch,
) -> None:
    _set_route_limit(monkeypatch, "50")
    try:
        headers_admin = admin_headers(client)
        seed_sea_links(client)
        mainland_stops = [
            create_destination(
                client,
                headers_admin,
                {
                    **DESTINATION_B,
                    "name": f"Mainland {idx + 1}",
                    "lat": 7.06 + idx * 0.005,
                    "lng": 125.58 + idx * 0.004,
                    "stay_duration_type": "short",
                },
            )
            for idx in range(12)
        ]
        samal_a = samal_destination(client, headers_admin, "Samal Spot A", 7.0744, 125.7087)
        samal_b = samal_destination(client, headers_admin, "Samal Spot B", 7.1200, 125.7200)
        ids = [
            *[s["destination_id"] for s in mainland_stops],
            samal_a["destination_id"],
            samal_b["destination_id"],
            mainland_stops[0]["destination_id"],
        ]

        class _PlanRoadFake(OSRMClient):
            provider_name = "mapbox"

            def __init__(self):
                pass

            async def matrix(self, *, travel_mode, coordinates):
                n = len(coordinates)
                return OSRMMatrixResult(
                    durations_seconds=[
                        [0.0 if i == j else 600.0 for j in range(n)]
                        for i in range(n)
                    ],
                    distances_meters=[
                        [0.0 if i == j else 4000.0 for j in range(n)]
                        for i in range(n)
                    ],
                )

            async def preview_route(self, *, travel_mode, coordinates):
                pts = [(c.lat, c.lng) for c in coordinates]
                return OSRMRouteResult(
                    total_distance_meters=1000.0 * (len(pts) - 1),
                    total_duration_seconds=300.0 * (len(pts) - 1),
                    legs=[
                        OSRMLeg(distance_meters=1000.0, duration_seconds=300.0)
                        for _ in pts[1:]
                    ],
                    polyline=encode_polyline5(pts),
                    provider="mapbox",
                )

        client.app.dependency_overrides[get_osrm_client] = _PlanRoadFake
        resp = client.post(
            "/api/v1/routes/plan/guest",
            json={
                "destination_ids": ids,
                "travel_mode": "driving",
                "days": 5,
                "pace": "balanced",
            },
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert len(body["days"]) == 5
        assert body["route"]["sea_crossings"]
        assert body["route"]["is_estimated"] is False
    finally:
        monkeypatch.undo()
        get_settings.cache_clear()

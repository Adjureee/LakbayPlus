from app.integrations.google_routes.errors import GoogleRoutesClientError
from tests.e2e.conftest import FakeGoogleRoutesClient
from tests.e2e.helpers import (
    register_admin,
    register_user,
    seed_davao_samal_network,
    seed_destination,
)


# ---------------------------------------------------------------------------
# F1 (R1) — Live Traffic Accuracy & Status Metadata
# ---------------------------------------------------------------------------


def test_f1_preview_route_live_traffic_status_and_congestion(client, e2e_fakes) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    stop_a = seed_destination(client, admin_headers, name="People's Park Davao", lat=7.0644, lng=125.6078)
    stop_b = seed_destination(client, admin_headers, name="Jack's Ridge", lat=7.0609, lng=125.5801)

    e2e_fakes.google_routes = FakeGoogleRoutesClient(
        is_configured=True,
        delay_seconds_per_leg=420.0,
    )

    resp = client.post(
        "/api/v1/routes/preview",
        headers=user_headers,
        json={
            "destination_ids": [stop_a["destination_id"], stop_b["destination_id"]],
            "travel_mode": "driving",
            "use_live_traffic": True,
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    traffic = body.get("traffic")
    assert traffic is not None
    assert traffic["status"] == "live"
    assert isinstance(traffic.get("delay_seconds"), int)
    assert traffic["delay_seconds"] > 0
    has_congestion = bool(
        traffic.get("congestion_segments")
        or traffic.get("traffic_level") in {"light", "moderate", "heavy", "severe"}
        or any(leg.get("traffic_level") for leg in body.get("legs", []))
    )
    assert has_congestion


def test_f1_plan_route_live_traffic_status(client, e2e_fakes) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    stops = [
        seed_destination(client, admin_headers, name="Abreeza Stop", lat=7.0913, lng=125.6114),
        seed_destination(client, admin_headers, name="Crocodile Park", lat=7.0994, lng=125.6197),
        seed_destination(client, admin_headers, name="Eden Nature Park", lat=7.0320, lng=125.4420),
    ]

    e2e_fakes.google_routes = FakeGoogleRoutesClient(
        is_configured=True,
        delay_seconds_per_leg=240.0,
    )

    resp = client.post(
        "/api/v1/routes/plan",
        headers=user_headers,
        json={
            "destination_ids": [s["destination_id"] for s in stops],
            "days": 2,
            "pace": "balanced",
            "travel_mode": "driving",
            "use_live_traffic": True,
        },
    )
    assert resp.status_code == 200, resp.text
    route = resp.json()["route"]
    assert route["traffic"] is not None
    assert route["traffic"]["status"] == "live"
    assert route["traffic"]["delay_seconds"] > 0


def test_f1_preview_route_limited_coverage_does_not_fabricate_live_traffic(
    client,
    e2e_fakes,
) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    stop_a = seed_destination(client, admin_headers, name="Mati Coastal Stop", lat=6.9551, lng=126.2166)
    stop_b = seed_destination(client, admin_headers, name="Dahican Beach", lat=6.9242, lng=126.2788)

    e2e_fakes.google_routes = FakeGoogleRoutesClient(
        is_configured=True,
        error=GoogleRoutesClientError("Live traffic coverage is limited in this region."),
    )

    resp = client.post(
        "/api/v1/routes/preview",
        headers=user_headers,
        json={
            "destination_ids": [stop_a["destination_id"], stop_b["destination_id"]],
            "travel_mode": "driving",
            "use_live_traffic": True,
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["polyline"]
    traffic = body.get("traffic_info") or body.get("traffic")
    assert traffic is not None
    assert traffic["status"] == "limited_coverage"
    assert traffic.get("delay_seconds") in (None, 0)


def test_f1_preview_route_unavailable_no_provider(client, e2e_fakes) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    stop_a = seed_destination(client, admin_headers, name="Tagum Stop", lat=7.4478, lng=125.8078)
    stop_b = seed_destination(client, admin_headers, name="Nabunturan Stop", lat=7.6033, lng=125.9667)

    e2e_fakes.google_routes = FakeGoogleRoutesClient(is_configured=False)

    resp = client.post(
        "/api/v1/routes/preview",
        headers=user_headers,
        json={
            "destination_ids": [stop_a["destination_id"], stop_b["destination_id"]],
            "travel_mode": "driving",
            "use_live_traffic": True,
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    traffic = body.get("traffic_info") or body.get("traffic")
    assert traffic is not None
    assert traffic["status"] == "unavailable_no_provider"
    assert len(e2e_fakes.google_routes.calls) == 0


def test_f1_preview_route_disabled_when_use_live_traffic_false(client, e2e_fakes) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    stop_a = seed_destination(client, admin_headers, name="Sta Ana Stop", lat=7.0762, lng=125.6258)
    stop_b = seed_destination(client, admin_headers, name="Roxas Ave Stop", lat=7.0722, lng=125.6131)

    e2e_fakes.google_routes = FakeGoogleRoutesClient(is_configured=True)

    resp = client.post(
        "/api/v1/routes/preview",
        headers=user_headers,
        json={
            "destination_ids": [stop_a["destination_id"], stop_b["destination_id"]],
            "travel_mode": "driving",
            "use_live_traffic": False,
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    traffic = body.get("traffic_info") or body.get("traffic")
    assert traffic is not None
    assert traffic["status"] == "disabled"
    assert len(e2e_fakes.google_routes.calls) == 0


# ---------------------------------------------------------------------------
# F2 (R2) — Multi-Day Routing, Consecutive Deduplication & Sea Crossings
# ---------------------------------------------------------------------------


def test_f2_plan_route_five_day_multi_stop_itinerary(client) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    coords = [
        ("People's Park", 7.0644, 125.6078, "full_day"),
        ("Philippine Eagle Center", 7.1859, 125.4152, "full_day"),
        ("Eden Nature Park", 7.0320, 125.4420, "full_day"),
        ("Malagos Garden Resort", 7.1892, 125.4241, "half_day"),
        ("Tagum Energy Park", 7.4201, 125.8140, "half_day"),
        ("Sleeping Dinosaur Mati", 6.9600, 126.1912, "full_day"),
    ]
    stops = [
        seed_destination(
            client,
            admin_headers,
            name=name,
            lat=lat,
            lng=lng,
            stay_duration_type=stay,
        )
        for name, lat, lng, stay in coords
    ]

    resp = client.post(
        "/api/v1/routes/plan",
        headers=user_headers,
        json={
            "destination_ids": [s["destination_id"] for s in stops],
            "days": 5,
            "pace": "relaxed",
            "travel_mode": "driving",
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assigned_ids = {
        stop["destination_id"]
        for day in body["days"]
        for stop in day["stops"]
        if stop["destination_id"] is not None
    }
    assert assigned_ids == {s["destination_id"] for s in stops}
    assert body["route"]["polyline"]
    assert not body["route"]["is_estimated"]
    assert len(body["route"]["stops"]) == len(stops)


def test_f2_consecutive_duplicates_collapsed_while_hub_revisit_preserved(client) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    hub_davao = seed_destination(client, admin_headers, name="Davao Hub", lat=7.0731, lng=125.6128)
    dig_stop = seed_destination(client, admin_headers, name="Digos Stop", lat=6.7496, lng=125.3572)

    a = hub_davao["destination_id"]
    b = dig_stop["destination_id"]

    resp = client.post(
        "/api/v1/routes/preview",
        headers=user_headers,
        json={
            "destination_ids": [a, a, b, a],
            "travel_mode": "driving",
        },
    )
    assert resp.status_code == 200, resp.text
    stop_ids = [s["destination_id"] for s in resp.json()["stops"]]
    assert stop_ids == [a, b, a]


def test_f2_multimodal_road_and_sea_segments_mainland_to_samal(client) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    seed_davao_samal_network(client, admin_headers)

    mainland_stop = seed_destination(
        client,
        admin_headers,
        name="Davao City Hall",
        lat=7.0644,
        lng=125.6078,
        island_group="mainland",
    )
    samal_stop = seed_destination(
        client,
        admin_headers,
        name="Hagimit Falls Samal",
        lat=7.0785,
        lng=125.7412,
        island_group="samal",
    )

    resp = client.post(
        "/api/v1/routes/plan",
        headers=user_headers,
        json={
            "destination_ids": [mainland_stop["destination_id"], samal_stop["destination_id"]],
            "days": 2,
            "travel_mode": "driving",
        },
    )
    assert resp.status_code == 200, resp.text
    route = resp.json()["route"]
    assert len(route["sea_crossings"]) >= 1
    modes = {seg["mode"] for seg in route["segments"]}
    assert "road" in modes
    assert "sea" in modes


def test_f2_optimize_route_preserves_first_destination(client) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    stop_a = seed_destination(client, admin_headers, name="First Davao Stop", lat=7.0644, lng=125.6078)
    stop_b = seed_destination(client, admin_headers, name="Second Davao Stop", lat=7.0994, lng=125.6197)
    stop_c = seed_destination(client, admin_headers, name="Third Davao Stop", lat=7.1907, lng=125.4553)

    resp = client.post(
        "/api/v1/routes/optimize",
        headers=user_headers,
        json={
            "destination_ids": [
                stop_a["destination_id"],
                stop_b["destination_id"],
                stop_c["destination_id"],
            ],
            "travel_mode": "driving",
            "preserve_first_destination": True,
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["stops"][0]["destination_id"] == stop_a["destination_id"]
    assert len(body["legs"]) == 2


def test_f2_guest_plan_route_without_auth_token(client) -> None:
    admin_headers, _ = register_admin(client)
    s1 = seed_destination(client, admin_headers, name="Public Stop 1", lat=7.0644, lng=125.6078)
    s2 = seed_destination(client, admin_headers, name="Public Stop 2", lat=7.0994, lng=125.6197)
    s3 = seed_destination(client, admin_headers, name="Public Stop 3", lat=7.1500, lng=125.6400)

    resp = client.post(
        "/api/v1/routes/plan/guest",
        json={
            "destination_ids": [s1["destination_id"], s2["destination_id"], s3["destination_id"]],
            "days": 3,
            "travel_mode": "driving",
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert len(body["days"]) >= 1
    assert len(body["route"]["stops"]) == 3

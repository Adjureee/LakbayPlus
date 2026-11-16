"""Tests for admin sea-port/link CRUD and destination custom access trails."""

from app.features.routes.polyline import decode_polyline5, encode_polyline5
from app.integrations.osrm.client import get_osrm_client
from app.integrations.osrm.schemas import OSRMLeg, OSRMRouteResult
from tests.test_phase6_routes import (
    DESTINATION_A,
    DESTINATION_B,
    FakeOSRMClient,
    admin_headers,
    create_destination,
    user_headers,
)


def test_admin_sea_ports_and_links_crud_and_route_reflection(client) -> None:
    admin = admin_headers(client)
    traveler = user_headers(client)

    # Travelers cannot access admin sea-link management endpoints.
    assert client.get("/api/v1/admin/sea-ports", headers=traveler).status_code == 403
    assert client.get("/api/v1/admin/sea-links", headers=traveler).status_code == 403

    port_a_res = client.post(
        "/api/v1/admin/sea-ports",
        headers=admin,
        json={
            "name": "Sta. Ana Admin Gate",
            "lat": 7.0762,
            "lng": 125.6258,
            "island_group": "mainland",
            "province": "Davao City",
            "source_url": "https://osm.org/node/1001",
            "verified": True,
        },
    )
    assert port_a_res.status_code == 201, port_a_res.text
    port_a = port_a_res.json()
    assert port_a["verified"] is True
    assert port_a["verified_at"] is not None

    # Duplicate port names return 409.
    dup_res = client.post(
        "/api/v1/admin/sea-ports",
        headers=admin,
        json={
            "name": "Sta. Ana Admin Gate",
            "lat": 7.0762,
            "lng": 125.6258,
            "island_group": "mainland",
        },
    )
    assert dup_res.status_code == 409

    port_b = client.post(
        "/api/v1/admin/sea-ports",
        headers=admin,
        json={
            "name": "Samal West Pier",
            "lat": 7.0910,
            "lng": 125.6680,
            "island_group": "samal",
            "verified": True,
        },
    ).json()

    boat_track = encode_polyline5([
        (7.0762, 125.6258),
        (7.0815, 125.6470),
        (7.0910, 125.6680),
    ])

    # Self-loop links are rejected.
    bad_loop = client.post(
        "/api/v1/admin/sea-links",
        headers=admin,
        json={
            "from_port_id": port_a["port_id"],
            "to_port_id": port_a["port_id"],
            "crossing_minutes": 15,
        },
    )
    assert bad_loop.status_code == 422

    # Invalid polyline fails validation cleanly.
    bad_poly = client.post(
        "/api/v1/admin/sea-links",
        headers=admin,
        json={
            "from_port_id": port_a["port_id"],
            "to_port_id": port_b["port_id"],
            "crossing_minutes": 15,
            "geometry_polyline": "not-valid-!",
        },
    )
    assert bad_poly.status_code == 422

    link_res = client.post(
        "/api/v1/admin/sea-links",
        headers=admin,
        json={
            "from_port_id": port_a["port_id"],
            "to_port_id": port_b["port_id"],
            "vessel_type": "roro_barge",
            "allows_private_vehicle": True,
            "crossing_minutes": 18,
            "typical_wait_minutes": 10,
            "fare_passenger": "35.00",
            "geometry_polyline": boat_track,
            "verified": True,
        },
    )
    assert link_res.status_code == 201, link_res.text
    link = link_res.json()
    assert link["from_port_name"] == "Sta. Ana Admin Gate"
    assert link["to_port_name"] == "Samal West Pier"
    assert link["geometry_polyline"] == boat_track
    assert link["verified"] is True

    # Adjust the boat track & port gate; verify updated route reflects the custom sea track.
    moved_track = encode_polyline5([
        (7.0765, 125.6261),
        (7.0840, 125.6455),
        (7.0910, 125.6680),
    ])
    client.patch(
        f"/api/v1/admin/sea-ports/{port_a['port_id']}",
        headers=admin,
        json={"lat": 7.0765, "lng": 125.6261},
    ).raise_for_status()
    updated_link = client.patch(
        f"/api/v1/admin/sea-links/{link['link_id']}",
        headers=admin,
        json={"geometry_polyline": moved_track, "crossing_minutes": 20},
    )
    assert updated_link.status_code == 200
    assert updated_link.json()["crossing_minutes"] == 20
    assert updated_link.json()["geometry_polyline"] == moved_track

    mainland = create_destination(client, admin, {**DESTINATION_A, "lat": 7.070, "lng": 125.610})
    samal = create_destination(client, admin, {
        **DESTINATION_B, "name": "Samal Point", "lat": 7.095, "lng": 125.675, "island_group": "samal",
    })

    class _RunOsrm:
        async def preview_route_with_snap_limits(self, *, travel_mode, coordinates, max_snap_meters=None):
            _ = travel_mode, max_snap_meters
            pts = [(c.lat, c.lng) for c in coordinates]
            return OSRMRouteResult(
                total_distance_meters=3000,
                total_duration_seconds=360,
                legs=[OSRMLeg(distance_meters=3000, duration_seconds=360)],
                polyline=encode_polyline5(pts),
                waypoint_snaps=[(p[0], p[1], 15.0) for p in pts],
            )

    client.app.dependency_overrides[get_osrm_client] = lambda: _RunOsrm()
    route_res = client.post(
        "/api/v1/routes/preview",
        headers=traveler,
        json={"destination_ids": [mainland["destination_id"], samal["destination_id"]]},
    )
    assert route_res.status_code == 200
    route = route_res.json()
    sea_segments = [seg for seg in route["segments"] if seg["mode"] == "sea"]
    assert len(sea_segments) == 1
    assert sea_segments[0]["polyline"] == moved_track
    assert route["sea_crossings"][0]["crossing_minutes"] == 20

    # Clearing geometry_polyline resets cleanly to null.
    cleared = client.patch(
        f"/api/v1/admin/sea-links/{link['link_id']}",
        headers=admin,
        json={"geometry_polyline": ""},
    )
    assert cleared.status_code == 200
    assert cleared.json()["geometry_polyline"] is None


def test_destination_access_trail_polyline_and_island_group_in_routes(client) -> None:
    admin = admin_headers(client)
    traveler = user_headers(client)

    origin_dest = create_destination(client, admin, {
        **DESTINATION_A, "name": "Davao City Gate", "lat": 7.0731, "lng": 125.6128,
    })
    resort = create_destination(client, admin, {
        **DESTINATION_B,
        "name": "Hidden Valley Beach",
        "lat": 7.3476,
        "lng": 126.1514,
        "island_group": "samal",
    })

    # Admin corrects island_group back to mainland ("") and attaches an access trail.
    trail_points = [(7.3400, 126.1450), (7.3442, 126.1481), (7.3476, 126.1514)]
    trail_poly = encode_polyline5(trail_points)
    patched = client.patch(
        f"/api/v1/destinations/{resort['destination_id']}",
        headers=admin,
        json={
            "island_group": "",
            "access_trail_polyline": trail_poly,
        },
    )
    assert patched.status_code == 200, patched.text
    assert patched.json()["island_group"] is None
    assert patched.json()["access_trail_polyline"] == trail_poly

    main_road = encode_polyline5([(7.0731, 125.6128), (7.2000, 125.9000), (7.3400, 126.1450)])
    fake_osrm = FakeOSRMClient(
        preview_result=OSRMRouteResult(
            total_distance_meters=64000,
            total_duration_seconds=4500,
            legs=[OSRMLeg(distance_meters=64000, duration_seconds=4500)],
            polyline=main_road,
            waypoint_snaps=[(7.0731, 125.6128, 12.0), (7.3400, 126.1450, 18.0)],
        ),
    )
    client.app.dependency_overrides[get_osrm_client] = lambda: fake_osrm

    res = client.post(
        "/api/v1/routes/preview",
        headers=traveler,
        json={"destination_ids": [origin_dest["destination_id"], resort["destination_id"]]},
    )
    assert res.status_code == 200, res.text
    body = res.json()
    assert body["is_estimated"] is False
    # Second segment is the mapped non-estimated access trail from road gate to pin.
    assert [(s["mode"], s["is_estimated"]) for s in body["segments"]] == [
        ("road", False),
        ("road", False),
    ]
    assert decode_polyline5(body["segments"][1]["polyline"]) == trail_points
    assert not any("not yet verified" in w for w in body["warnings"])

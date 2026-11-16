"""Island trips drive to a pier, cross by boat, and drive on — never by road over water."""

import asyncio
from decimal import Decimal

from app.db.session import get_db_session
from app.features.routes.polyline import decode_polyline5, encode_polyline5, join_polylines5
from app.features.routes.sea_planner import (
    PlannerLink,
    PlannerPoint,
    PlannerPort,
    SeaNetwork,
)
from app.features.sea_links.models import SeaLink, SeaPort
from app.integrations.osrm.client import get_osrm_client
from app.integrations.osrm.errors import OSRMClientError
from app.integrations.osrm.schemas import OSRMLeg, OSRMRouteResult
from tests.test_phase6_routes import (
    DESTINATION_A,
    admin_headers,
    create_destination,
    user_headers,
)

SASA = PlannerPort(1, "Sasa RoRo Wharf", 7.1236, 125.6655, "mainland")
BABAK = PlannerPort(2, "Babak RoRo Landing", 7.1180, 125.6880, "samal")
STA_ANA = PlannerPort(3, "Sta. Ana Wharf", 7.0760, 125.6260, "mainland")
TALIKUD = PlannerPort(4, "Talikud Pier", 6.9530, 125.6990, "talikud")
RORO = PlannerLink(10, 1, 2, "roro_barge", True, 15, 20)
TALIKUD_BOAT = PlannerLink(11, 3, 4, "passenger_ferry", False, 60, 45)

DOWNTOWN = PlannerPoint(7.0707, 125.6096, None)
SAMAL_BEACH = PlannerPoint(7.0744, 125.7087, "samal")
TALIKUD_BEACH = PlannerPoint(6.9400, 125.7000, "talikud")


def network() -> SeaNetwork:
    return SeaNetwork([SASA, BABAK, STA_ANA, TALIKUD], [RORO, TALIKUD_BOAT])


# --- polyline -----------------------------------------------------------------

def test_polyline_round_trip_and_join() -> None:
    points = [(7.07071, 125.60961), (7.12360, 125.66550), (7.11800, 125.68800)]
    assert decode_polyline5(encode_polyline5(points)) == points
    joined = join_polylines5([encode_polyline5(points[:2]), encode_polyline5(points[1:])])
    assert decode_polyline5(joined) == points


# --- sea planner --------------------------------------------------------------

def test_mainland_to_samal_uses_the_roro_pier() -> None:
    path = network().find_path(DOWNTOWN, SAMAL_BEACH, driving=True)
    assert path is not None
    assert [(hop.board.name, hop.land.name) for hop in path.hops] == [
        ("Sasa RoRo Wharf", "Babak RoRo Landing"),
    ]


def test_return_trip_reverses_the_link() -> None:
    path = network().find_path(SAMAL_BEACH, DOWNTOWN, driving=True)
    assert [(hop.board.name, hop.land.name, hop.reversed_geometry) for hop in path.hops] == [
        ("Babak RoRo Landing", "Sasa RoRo Wharf", True),
    ]


def test_samal_to_talikud_transfers_via_the_mainland() -> None:
    path = network().find_path(SAMAL_BEACH, TALIKUD_BEACH, driving=False)
    assert [(hop.board.island_group, hop.land.island_group) for hop in path.hops] == [
        ("samal", "mainland"), ("mainland", "talikud"),
    ]


def test_same_island_needs_no_boat_and_unknown_island_has_no_path() -> None:
    assert network().find_path(DOWNTOWN, PlannerPoint(7.19, 125.45, None), driving=True).hops == []
    assert network().find_path(DOWNTOWN, PlannerPoint(5.4, 125.38, "balut"), driving=True) is None


def test_order_costs_keep_island_stops_together() -> None:
    from app.features.routes.ordering import exact_order

    stops = [
        DOWNTOWN,
        SAMAL_BEACH,
        PlannerPoint(7.19, 125.45, None),  # mainland, far west
        PlannerPoint(7.12, 125.72, "samal"),
    ]
    costs = network().order_costs(stops, driving=True)
    order = exact_order(costs, fixed_start=True, roundtrip=False)
    groups = [stops[index].island_group for index in order]
    # One crossing only: the two Samal stops are adjacent.
    crossings = sum(1 for a, b in zip(groups, groups[1:]) if a != b)
    assert crossings == 1


# --- route API ----------------------------------------------------------------

class RoadFake:
    """Returns a straight-road answer for any coordinates, like OSRM would."""

    provider_name = "mapbox"

    def __init__(self, fail_on: set[str] | None = None) -> None:
        self.calls: list[list[tuple[float, float]]] = []
        self.fail_on = fail_on or set()

    async def preview_route(self, *, travel_mode, coordinates):
        coords = [(item.lat, item.lng) for item in coordinates]
        self.calls.append(coords)
        if any(item.label in self.fail_on for item in coordinates):
            raise OSRMClientError("No road.")
        return OSRMRouteResult(
            total_distance_meters=1000.0 * (len(coords) - 1),
            total_duration_seconds=600.0 * (len(coords) - 1),
            legs=[OSRMLeg(distance_meters=1000, duration_seconds=600) for _ in coords[1:]],
            polyline=encode_polyline5(coords),
            provider="mapbox",
        )

    async def matrix(self, **kwargs):
        raise OSRMClientError("unused")

    async def optimize_route(self, **kwargs):
        raise OSRMClientError("unused")


def seed_sea_links(client) -> None:
    async def run() -> None:
        sessions = client.app.dependency_overrides[get_db_session]()
        session = await sessions.__anext__()
        session.add_all([
            SeaPort(port_id=1, name=SASA.name, lat=SASA.lat, lng=SASA.lng, island_group="mainland"),
            SeaPort(port_id=2, name=BABAK.name, lat=BABAK.lat, lng=BABAK.lng, island_group="samal"),
        ])
        await session.flush()
        session.add(SeaLink(
            from_port_id=1, to_port_id=2, vessel_type="roro_barge",
            allows_private_vehicle=True, crossing_minutes=15, typical_wait_minutes=20,
            schedule_text="Every 30 min, daytime", fare_vehicle=Decimal("180.00"),
        ))
        await session.commit()
        await sessions.aclose()

    asyncio.run(run())


def samal_destination(client, headers, name="Samal Beach", lat=7.0744, lng=125.7087) -> dict:
    return create_destination(client, headers, {
        **DESTINATION_A, "name": name, "lat": lat, "lng": lng,
        "location": "Island Garden City of Samal", "island_group": "samal",
    })


def test_preview_to_samal_drives_to_pier_then_crosses(client) -> None:
    headers = admin_headers(client)
    city = create_destination(client, headers, DESTINATION_A)
    beach = samal_destination(client, headers)
    assert beach["island_group"] == "samal"
    seed_sea_links(client)
    road = RoadFake()
    client.app.dependency_overrides[get_osrm_client] = lambda: road

    response = client.post("/api/v1/routes/preview", headers=user_headers(client), json={
        "destination_ids": [city["destination_id"], beach["destination_id"]],
        "travel_mode": "driving",
    })

    assert response.status_code == 200, response.text
    body = response.json()
    # Two road runs: city -> Sasa pier, then Babak landing -> beach. Never city -> beach.
    assert road.calls == [
        [(DESTINATION_A["lat"], DESTINATION_A["lng"]), (SASA.lat, SASA.lng)],
        [(BABAK.lat, BABAK.lng), (7.0744, 125.7087)],
    ]
    assert body["route_provider"] == "mapbox+sea_links"
    assert body["is_estimated"] is False
    assert [segment["mode"] for segment in body["segments"]] == ["road", "sea", "road"]
    assert all(segment["polyline"] for segment in body["segments"])
    assert len(body["legs"]) == 1
    crossing = body["legs"][0]["sea_crossings"][0]
    assert crossing["board_port"] == SASA.name and crossing["land_port"] == BABAK.name
    assert crossing["verified"] is False
    # 2 road km + sea km; 10 + 10 road min + 15 crossing + 20 wait.
    assert body["legs"][0]["duration_minutes"] == 55
    assert Decimal(body["sea_distance_km"]) > 0
    assert any("Sasa RoRo Wharf" in warning and "not yet verified" in warning
               for warning in body["warnings"])
    assert [step["instruction"] for step in body["legs"][0]["steps"]] == [
        f"Board the RoRo barge at {SASA.name} to {BABAK.name}",
    ]


def test_failed_road_run_is_estimated_without_geometry(client) -> None:
    headers = admin_headers(client)
    city = create_destination(client, headers, DESTINATION_A)
    beach = samal_destination(client, headers)
    seed_sea_links(client)
    road = RoadFake(fail_on={"Samal Beach"})
    client.app.dependency_overrides[get_osrm_client] = lambda: road

    body = client.post("/api/v1/routes/preview", headers=user_headers(client), json={
        "destination_ids": [city["destination_id"], beach["destination_id"]],
    }).json()

    assert body["is_estimated"] is True
    road_segments = [segment for segment in body["segments"] if segment["mode"] == "road"]
    assert [segment["is_estimated"] for segment in road_segments] == [False, True]
    assert road_segments[1]["polyline"]  # dashed connector only
    assert body["polyline"] is None


def test_island_without_pier_link_is_reported(client) -> None:
    headers = admin_headers(client)
    city = create_destination(client, headers, DESTINATION_A)
    balut = create_destination(client, headers, {
        **DESTINATION_A, "name": "Balut", "lat": 5.40, "lng": 125.38, "island_group": "balut",
    })
    seed_sea_links(client)
    road = RoadFake()
    client.app.dependency_overrides[get_osrm_client] = lambda: road

    body = client.post("/api/v1/routes/preview", headers=user_headers(client), json={
        "destination_ids": [city["destination_id"], balut["destination_id"]],
    }).json()

    assert body["unconnected_island_groups"] == ["balut"]
    assert body["is_estimated"] is True
    assert road.calls == []


def test_optimize_visits_samal_stops_together(client) -> None:
    headers = admin_headers(client)
    city = create_destination(client, headers, DESTINATION_A)
    beach_1 = samal_destination(client, headers, "Samal Beach 1", 7.0744, 125.7087)
    far_west = create_destination(client, headers, {
        **DESTINATION_A, "name": "Calinan", "lat": 7.19, "lng": 125.45,
    })
    beach_2 = samal_destination(client, headers, "Samal Beach 2", 7.12, 125.72)
    seed_sea_links(client)
    client.app.dependency_overrides[get_osrm_client] = lambda: RoadFake()

    body = client.post("/api/v1/routes/optimize", headers=user_headers(client), json={
        "destination_ids": [
            city["destination_id"], beach_1["destination_id"],
            far_west["destination_id"], beach_2["destination_id"],
        ],
        "preserve_first_destination": True,
    }).json()

    assert body["order_method"] == "island_aware"
    names = [stop["name"] for stop in body["stops"]]
    samal_positions = [index for index, name in enumerate(names) if name.startswith("Samal")]
    assert samal_positions[1] - samal_positions[0] == 1
    assert len(body["sea_crossings"]) == 1


def test_sea_port_allows_wider_osrm_snap_while_stops_stay_strict(client, monkeypatch) -> None:
    """Piers like Sasa RoRo Wharf sit >250 m off the highway centerline inside port compounds."""
    import httpx
    from app.integrations.osrm import client as osrm_module
    from app.integrations.osrm.client import OSRMClient

    headers = admin_headers(client)
    panabo = create_destination(client, headers, {
        **DESTINATION_A, "name": "Panabo Highway", "lat": 7.2990, "lng": 125.6740,
    })
    samal = samal_destination(client, headers, "Aqua Water Park", 7.08705, 125.66662)
    seed_sea_links(client)

    body_panabo_sasa = {
        "code": "Ok",
        "routes": [{
            "distance": 21500, "duration": 1800,
            "geometry": encode_polyline5([(7.299, 125.674), (7.1236, 125.6655)]),
            "legs": [{"distance": 21500, "duration": 1800, "steps": [
                {"distance": 21500, "duration": 1800, "mode": "driving", "name": "Maharlika Hwy",
                 "maneuver": {"type": "depart", "location": [125.674, 7.299]}},
            ]}],
        }],
        "waypoints": [{"distance": 41.8}, {"distance": 393.7}],
    }
    body_babak_aqua = {
        "code": "Ok",
        "routes": [{
            "distance": 4900, "duration": 480,
            "geometry": encode_polyline5([(7.118, 125.688), (7.08705, 125.66662)]),
            "legs": [{"distance": 4900, "duration": 480, "steps": [
                {"distance": 4900, "duration": 480, "mode": "driving", "name": "Samal Rd",
                 "maneuver": {"type": "depart", "location": [125.688, 7.118]}},
            ]}],
        }],
        "waypoints": [{"distance": 123.2}, {"distance": 29.2}],
    }
    responses = iter([body_panabo_sasa, body_babak_aqua])
    real_async_client = httpx.AsyncClient
    monkeypatch.setattr(
        osrm_module.httpx,
        "AsyncClient",
        lambda **kwargs: real_async_client(
            transport=httpx.MockTransport(lambda req: httpx.Response(200, json=next(responses))),
            **kwargs,
        ),
    )
    client.app.dependency_overrides[get_osrm_client] = lambda: OSRMClient()

    response = client.post("/api/v1/routes/preview", headers=user_headers(client), json={
        "destination_ids": [panabo["destination_id"], samal["destination_id"]],
        "travel_mode": "driving",
    })
    assert response.status_code == 200, response.text
    result = response.json()
    assert result["is_estimated"] is False
    assert [seg["mode"] for seg in result["segments"]] == ["road", "sea", "road"]
    assert all(not seg["is_estimated"] for seg in result["segments"])
    assert result["polyline"] is not None

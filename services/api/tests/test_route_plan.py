"""Tests for adaptive route planning, Or-opt, Linear-Partition DP, and /routes/plan."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from app.core.config import get_settings
from app.features.routes.day_planner import (
    StopPlanInput,
    plan_days,
    plan_multi_day_route,
)
from app.features.routes.ordering import _or_opt, order_cost
from app.features.routes.sea_planner import PlannerPoint, SeaNetwork
from app.integrations.osrm.client import get_osrm_client
from app.integrations.osrm.errors import OSRMClientError
from app.integrations.osrm.schemas import OSRMMatrixResult
from tests.test_phase6_routes import (
    DESTINATION_A,
    DESTINATION_B,
    admin_headers,
    create_destination,
    user_headers,
)
from tests.test_sea_routing import (
    BABAK,
    RORO,
    SASA,
    STA_ANA,
    TALIKUD,
    TALIKUD_BOAT,
    RoadFake,
    seed_sea_links,
)

PARITY_FIXTURE = (
    Path(__file__).resolve().parents[3]
    / "apps"
    / "traveler_app"
    / "test"
    / "fixtures"
    / "route_parity_case.json"
)


class MatrixFake(RoadFake):
    """Fake OSRM/Mapbox client supporting pairwise distance/duration matrices."""

    def __init__(self, *, provider: str = "mapbox", fail_matrix: bool = False) -> None:
        super().__init__()
        self.provider_name = provider
        self.fail_matrix = fail_matrix
        self.matrix_calls: list[list[tuple[float, float]]] = []

    async def matrix(self, *, travel_mode, coordinates):
        if self.fail_matrix:
            raise OSRMClientError("Matrix offline.")
        coords = [(item.lat, item.lng) for item in coordinates]
        self.matrix_calls.append(coords)
        n = len(coords)
        durations = [[0.0] * n for _ in range(n)]
        distances = [[0.0] * n for _ in range(n)]
        for i in range(n):
            for j in range(n):
                if i == j:
                    continue
                dlat = coords[i][0] - coords[j][0]
                dlng = coords[i][1] - coords[j][1]
                km = ((dlat**2 + dlng**2) ** 0.5) * 111.0 * 1.25
                distances[i][j] = round(km * 1000.0, 1)
                durations[i][j] = round((km / 42.0) * 3600.0, 1)
        return OSRMMatrixResult(
            durations_seconds=durations,
            distances_meters=distances,
        )


def _starter_network() -> SeaNetwork:
    return SeaNetwork([SASA, BABAK, STA_ANA, TALIKUD], [RORO, TALIKUD_BOAT])


def test_or_opt_improves_relocatable_subchain() -> None:
    # Stop chain [0, 1, 2, 3, 4, 5] with detour segment [2, 3] cheaper if moved near [4, 5].
    pts = [(0, 0), (1, 0), (10, 0), (11, 0), (2, 0), (3, 0)]
    costs = [
        [((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5 for b in pts]
        for a in pts
    ]
    base_order = [0, 1, 2, 3, 4, 5]
    improved = _or_opt(costs, base_order, fixed_start=True, roundtrip=False)
    assert order_cost(costs, improved, roundtrip=False) < order_cost(
        costs, base_order, roundtrip=False,
    )
    assert improved == [0, 1, 4, 5, 2, 3]


def test_parity_with_flutter_fixture_matches_contract() -> None:
    raw = json.loads(PARITY_FIXTURE.read_text(encoding="utf-8"))
    origin_data = raw["origin"]
    origin = PlannerPoint(
        origin_data["lat"],
        origin_data["lng"],
        origin_data["island_group"],
    )
    stops = [
        StopPlanInput(
            destination_id=idx + 1,
            name=item["name"],
            lat=item["lat"],
            lng=item["lng"],
            island_group=item["island_group"],
            stay_duration_type=item["stay_duration_type"],
        )
        for idx, item in enumerate(raw["stops"])
    ]

    result = plan_multi_day_route(
        stops=stops,
        days=raw["days"],
        pace=raw["pace"],
        origin=origin,
        roundtrip=raw["roundtrip"],
        driving=raw["driving"],
        network=_starter_network(),
    )

    assert result.cost_source == "haversine"
    assert result.order_method == "island_aware"
    assert result.savings_vs_input.distance_saved_km > 10.0
    assert result.savings_vs_input.distance_saved_percent > 5.0
    assert len(result.days) == 3
    # Verify Samal stops grouped together cleanly in route stops & days.
    names = [s.name for s in result.ordered_stops]
    assert names == [
        "Eden Nature Park",
        "Philippine Eagle Center",
        "Monfort Bat Sanctuary",
        "Samal Island Beach Area",
        "Dahican Beach",
    ]
    assert result.savings_vs_input.baseline_distance_km == pytest.approx(304.93, abs=0.05)
    assert result.savings_vs_input.optimized_distance_km == pytest.approx(222.47, abs=0.05)
    assert result.savings_vs_input.distance_saved_km == pytest.approx(82.46, abs=0.05)
    assert result.savings_vs_input.distance_saved_percent == pytest.approx(27.0, abs=0.2)
    assert [len(d.stops) for d in result.days] == [2, 2, 1]
    assert names[-1] == "Dahican Beach"
    flattened = [s.name for d in result.days for s in d.stops]
    assert len(flattened) == 5 and len(set(flattened)) == 5


def test_plan_days_keeps_every_stop_once_and_emits_overload_warnings() -> None:
    stops = [
        StopPlanInput(1, "Park", 7.07, 125.61, None, "short"),
        StopPlanInput(2, "Eagle", 7.18, 125.42, None, "half_day"),
        StopPlanInput(3, "Dahican", 6.95, 126.25, None, "overnight"),
        StopPlanInput(4, "Museum", 7.08, 125.60, None, "full_day"),
    ]
    # Fewer days than stops: all 4 stops present, overnight forces day end + overload warning.
    tight, warnings = plan_days(
        stops,
        days=2,
        pace="relaxed",
        leg_transit_hours=[0.5, 2.5, 2.5],
    )
    assert len(tight) == 2
    assert [s.destination_id for d in tight for s in d.stops] == [1, 2, 3, 4]
    assert tight[0].stops[-1].name == "Dahican" or tight[1].stops[-1].name == "Museum"
    assert any("Add a day?" in w for w in warnings)

    # More days than stops: no duplicates, rest/continuation day attached cleanly.
    loose, _ = plan_days(
        stops,
        days=6,
        pace="balanced",
        leg_transit_hours=[0.5, 2.5, 2.5],
    )
    assert len(loose) == 6
    assert [s.destination_id for d in loose for s in d.stops] == [1, 2, 3, 4]
    assert any(d.is_continuation_day for d in loose)


def test_plan_endpoint_requires_auth_and_guest_endpoint_is_rate_limited(client, monkeypatch) -> None:
    headers = admin_headers(client)
    first = create_destination(client, headers, {**DESTINATION_A, "stay_duration_type": "short"})
    second = create_destination(client, headers, {**DESTINATION_B, "stay_duration_type": "half_day"})
    payload = {
        "destination_ids": [first["destination_id"], second["destination_id"]],
        "travel_mode": "public_transport",
        "days": 2,
        "pace": "balanced",
    }

    assert client.post("/api/v1/routes/plan", json=payload).status_code == 401

    monkeypatch.setenv("ROUTE_REQUESTS_PER_MINUTE", "2")
    get_settings.cache_clear()

    r1 = client.post("/api/v1/routes/plan/guest", json=payload)
    r2 = client.post("/api/v1/routes/plan/guest", json=payload)
    r3 = client.post("/api/v1/routes/plan/guest", json=payload)

    assert r1.status_code == 200, r1.text
    body = r1.json()
    assert body["cost_source"] == "haversine"
    assert body["pace"] == "balanced"
    assert len(body["days"]) == 2
    assert body["route"]["route_provider"] == "stored_transportation_estimate"
    assert r2.status_code == 200
    assert r3.status_code == 429
    assert r3.json()["error"]["code"] == "route_rate_limited"


def test_plan_endpoint_cross_island_matrix_savings_and_constraints(client) -> None:
    headers = admin_headers(client)
    seed_sea_links(client)
    city = create_destination(client, headers, {
        **DESTINATION_A, "name": "Davao City Park", "lat": 7.0707, "lng": 125.6096,
        "stay_duration_type": "short",
    })
    samal_a = create_destination(client, headers, {
        **DESTINATION_A, "name": "Samal Beach", "lat": 7.0744, "lng": 125.7087,
        "island_group": "samal", "stay_duration_type": "full_day",
    })
    eden = create_destination(client, headers, {
        **DESTINATION_A, "name": "Eden Park", "lat": 7.0088, "lng": 125.3992,
        "stay_duration_type": "half_day",
    })
    samal_b = create_destination(client, headers, {
        **DESTINATION_A, "name": "Monfort Samal", "lat": 7.1655, "lng": 125.6927,
        "island_group": "samal", "stay_duration_type": "half_day",
    })
    dahican = create_destination(client, headers, {
        **DESTINATION_A, "name": "Dahican Surf", "lat": 6.9487, "lng": 126.2542,
        "stay_duration_type": "overnight",
    })

    matrix_fake = MatrixFake(provider="mapbox", fail_matrix=False)
    client.app.dependency_overrides[get_osrm_client] = lambda: matrix_fake
    user = user_headers(client)

    resp = client.post(
        "/api/v1/routes/plan",
        headers=user,
        json={
            # Scrambled order oscillating between mainland and Samal.
            "destination_ids": [
                samal_a["destination_id"],
                eden["destination_id"],
                samal_b["destination_id"],
                city["destination_id"],
                dahican["destination_id"],
            ],
            "travel_mode": "driving",
            "days": 3,
            "pace": "balanced",
            "origin": {"label": "Hotel", "lat": 7.07, "lng": 125.61, "island_group": None},
            "locked_first_destination_id": city["destination_id"],
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["cost_source"] == "mapbox"
    assert body["order_method"] == "island_aware"
    assert body["savings_vs_input"]["distance_saved_km"] > 0
    assert body["days"][0]["stops"][0]["destination_id"] == city["destination_id"]
    all_stop_ids = [s["destination_id"] for d in body["days"] for s in d["stops"]]
    assert len(all_stop_ids) == 5
    # Verify Samal stops grouped together cleanly in route stops & days.
    names = [stop["name"] for stop in body["route"]["stops"]]
    samal_indices = [
        i for i, name in enumerate(names) if "Samal" in name
    ]
    assert len(samal_indices) == 2
    assert samal_indices[1] - samal_indices[0] == 1

    # Also verify optional-stop pruning when days are tight and must_visit is partial.
    tight = client.post(
        "/api/v1/routes/plan",
        headers=user,
        json={
            "destination_ids": [
                city["destination_id"],
                eden["destination_id"],
                dahican["destination_id"],
            ],
            "travel_mode": "driving",
            "days": 1,
            "pace": "relaxed",
            "must_visit_destination_ids": [
                city["destination_id"],
                eden["destination_id"],
            ],
            "prune_optional_to_fit": True,
        },
    )
    assert tight.status_code == 200, tight.text
    tight_body = tight.json()
    assert tight_body["skipped_destination_ids"] == [dahican["destination_id"]]
    assert [
        s["destination_id"] for d in tight_body["days"] for s in d["stops"]
    ] == [city["destination_id"], eden["destination_id"]]

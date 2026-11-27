"""Tests for AI itinerary geographic realism, coordinate hydration, and draft grounding."""

import json
from datetime import datetime, timezone
from decimal import Decimal
from types import SimpleNamespace

import pytest

from app.features.ai.schemas import AIItineraryGenerateRequest
from app.features.ai.service import _itinerary_quality_warnings
from app.features.ai.validators import (
    AIItineraryCatalog,
    AIOutputValidationError,
    parse_and_validate_itinerary_output,
)
from app.integrations.groq.client import get_groq_client
from tests.test_phase5_ai_itineraries import (
    FakeGroqClient,
    admin_headers,
    configure_ai,
    create_destination,
    user_headers,
)


def _multi_dest_valid_response(
    *,
    ordered_ids: list[int],
    option_count: int = 5,
    day_count: int = 2,
) -> str:
    options = []
    for option_number in range(1, option_count + 1):
        # Put first two stops on day 1 and remaining stop(s) on day 2, plus a lunch filler.
        day1_acts = [
            {
                "time": "08:30",
                "title": f"Morning visit stop {ordered_ids[0]}",
                "description": "Explore the first stop.",
                "destination_id": ordered_ids[0],
                "accommodation_id": None,
                "transportation_id": None,
                "estimated_cost": "300.00",
                "notes": None,
            },
            {
                "time": "12:00",
                "title": "Local lunch break",
                "description": "Rest and eat nearby.",
                "destination_id": None,
                "accommodation_id": None,
                "transportation_id": None,
                "estimated_cost": "200.00",
                "notes": None,
            },
        ]
        if len(ordered_ids) >= 2:
            day1_acts.append(
                {
                    "time": "14:00",
                    "title": f"Afternoon visit stop {ordered_ids[1]}",
                    "description": "Explore nearby second stop.",
                    "destination_id": ordered_ids[1],
                    "accommodation_id": None,
                    "transportation_id": None,
                    "estimated_cost": "300.00",
                    "notes": None,
                }
            )
        day2_acts = [
            {
                "time": "09:00",
                "title": f"Day 2 visit stop {ordered_ids[-1]}",
                "description": "Explore the final destination.",
                "destination_id": ordered_ids[-1],
                "accommodation_id": None,
                "transportation_id": None,
                "estimated_cost": "400.00",
                "notes": None,
            }
        ]
        total = Decimal("1200.00") if len(ordered_ids) >= 2 else Decimal("900.00")
        days = [{"day": 1, "title": "Day 1", "summary": "Clustered day 1.", "activities": day1_acts}]
        if day_count >= 2:
            days.append({"day": 2, "title": "Day 2", "summary": "Clustered day 2.", "activities": day2_acts})
        options.append(
            {
                "option_number": option_number,
                "title": f"Geo Option {option_number}",
                "summary": "Geographically ordered Davao Region plan.",
                "estimated_total_cost": f"{total:.2f}",
                "is_over_budget": False,
                "days": days,
            }
        )
    return json.dumps({"options": options})


def test_generate_itinerary_enforces_geo_order_and_hydrates_coordinates(
    client, monkeypatch
) -> None:
    configure_ai(monkeypatch)
    admin = admin_headers(client)
    samal_a = create_destination(
        client,
        headers=admin,
        name="Samal Coral Cove",
        district="Davao del Norte",
        location="Samal",
        island_group="samal",
        lat=7.081,
        lng=125.712,
    )
    mati_b = create_destination(
        client,
        headers=admin,
        name="Mati Surf Coast",
        district="Davao Oriental",
        location="Mati City",
        island_group=None,
        lat=6.951,
        lng=126.254,
    )
    samal_c = create_destination(
        client,
        headers=admin,
        name="Hagimit Samal Falls",
        district="Davao del Norte",
        location="Samal",
        island_group="samal",
        lat=7.053,
        lng=125.704,
    )
    id_a = samal_a["destination_id"]
    id_b = mati_b["destination_id"]
    id_c = samal_c["destination_id"]

    # First call sees zigzag order rejected if returned out-of-order, second returns grouped order.
    # Note: Samal A and Samal C must be adjacent (never Samal -> Mati -> Samal).
    expected_grouped = [id_a, id_c, id_b]

    class OrderInspectingGroqClient(FakeGroqClient):
        async def create_chat_completion(self, **kwargs):
            payload = json.loads(kwargs["messages"][-1]["content"])
            order = payload["required_destination_visit_order"]
            self.responses = [_multi_dest_valid_response(ordered_ids=order, day_count=2)]
            return await super().create_chat_completion(**kwargs)

    fake = OrderInspectingGroqClient([])
    client.app.dependency_overrides[get_groq_client] = lambda: fake

    response = client.post(
        "/api/v1/ai/itineraries/generate",
        headers=user_headers(client),
        json={
            "total_budget": "10000.00",
            "traveler_count": 2,
            "day_count": 2,
            "destination_ids": [id_a, id_b, id_c],
            "accommodation_ids": [],
            "transportation_ids": [],
            "interests": ["beach"],
            "allow_fallback": False,
        },
    )

    assert response.status_code == 200, response.text
    prompt_payload = json.loads(fake.calls[0]["messages"][-1]["content"])
    req_order = prompt_payload["required_destination_visit_order"]
    assert set(req_order) == {id_a, id_b, id_c}
    # Both Samal stops must stay contiguous (no Mati stop sandwiched in between).
    assert abs(req_order.index(id_a) - req_order.index(id_c)) == 1
    assert "geographic_guidance" in prompt_payload
    assert len(prompt_payload["geographic_guidance"]["suggested_day_clusters"]) == 2
    assert len(prompt_payload["geographic_guidance"]["consecutive_legs"]) == 2

    body = response.json()
    for opt in body["options"]:
        for day in opt["days"]:
            for act in day["activities"]:
                assert act["lat"] is not None
                assert act["lng"] is not None
                assert -90 <= act["lat"] <= 90
                assert -180 <= act["lng"] <= 180
                if act["destination_id"] == id_b:
                    assert act["lat"] == pytest.approx(6.951, abs=1e-4)
                    assert act["lng"] == pytest.approx(126.254, abs=1e-4)
                elif act["destination_id"] in (id_a, id_c):
                    assert act["island_group"] == "samal"


def test_validators_reject_island_ping_pong_and_far_same_day_jump() -> None:
    # 1. Island ping-pong: samal -> mainland -> samal
    ping_pong_payload = {
        "options": [
            {
                "option_number": i,
                "title": f"Opt {i}",
                "summary": "Ping pong",
                "estimated_total_cost": "300.00",
                "is_over_budget": False,
                "days": [
                    {
                        "day": 1,
                        "title": "D1",
                        "summary": "D1",
                        "activities": [
                            {
                                "time": "08:00",
                                "title": "Samal 1",
                                "description": "d",
                                "destination_id": 1,
                                "estimated_cost": "100.00",
                            },
                            {
                                "time": "13:00",
                                "title": "Mainland 2",
                                "description": "d",
                                "destination_id": 2,
                                "estimated_cost": "100.00",
                            },
                        ],
                    },
                    {
                        "day": 2,
                        "title": "D2",
                        "summary": "D2",
                        "activities": [
                            {
                                "time": "09:00",
                                "title": "Samal 3",
                                "description": "d",
                                "destination_id": 3,
                                "estimated_cost": "100.00",
                            },
                        ],
                    },
                ],
            }
            for i in range(1, 3)
        ]
    }
    catalog_island = AIItineraryCatalog(
        destination_ids={1, 2, 3},
        accommodation_ids=set(),
        transportation_ids=set(),
        total_budget=Decimal("5000.00"),
        day_count=2,
        minimum_option_count=2,
        required_destination_ids={1, 2, 3},
        destination_coords={1: (7.08, 125.71), 2: (7.07, 125.61), 3: (7.05, 125.70)},
        destination_island_groups={1: "samal", 2: "mainland", 3: "samal"},
    )
    with pytest.raises(AIOutputValidationError) as exc_info:
        parse_and_validate_itinerary_output(
            content=json.dumps(ping_pong_payload),
            catalog=catalog_island,
        )
    assert any("island groups" in err for err in exc_info.value.details)

    # 2. Unrealistic >140 km same-day jump on multi-day itinerary (Cateel 7.78,126.37 -> Balut 5.40,125.41 ~285 km)
    far_jump_payload = {
        "options": [
            {
                "option_number": i,
                "title": f"Opt {i}",
                "summary": "Far jump",
                "estimated_total_cost": "200.00",
                "is_over_budget": False,
                "days": [
                    {
                        "day": 1,
                        "title": "D1",
                        "summary": "D1",
                        "activities": [
                            {
                                "time": "08:00",
                                "title": "Cateel Falls",
                                "description": "d",
                                "destination_id": 10,
                                "estimated_cost": "100.00",
                            },
                            {
                                "time": "14:00",
                                "title": "Balut Island",
                                "description": "d",
                                "destination_id": 11,
                                "estimated_cost": "100.00",
                            },
                        ],
                    },
                    {
                        "day": 2,
                        "title": "D2",
                        "summary": "D2",
                        "activities": [
                            {
                                "time": "09:00",
                                "title": "Balut Cove",
                                "description": "d",
                                "destination_id": 11,
                                "estimated_cost": "0.00",
                            },
                        ],
                    },
                ],
            }
            for i in range(1, 3)
        ]
    }
    catalog_jump = AIItineraryCatalog(
        destination_ids={10, 11},
        accommodation_ids=set(),
        transportation_ids=set(),
        total_budget=Decimal("5000.00"),
        day_count=2,
        minimum_option_count=2,
        required_destination_ids={10, 11},
        destination_coords={10: (7.78, 126.37), 11: (5.40, 125.41)},
        destination_island_groups={10: "mainland", 11: "balut"},
    )
    with pytest.raises(AIOutputValidationError) as jump_exc:
        parse_and_validate_itinerary_output(
            content=json.dumps(far_jump_payload),
            catalog=catalog_jump,
        )
    assert any("apart" in err for err in jump_exc.value.details)


def test_trip_draft_grounds_catalog_places_drops_hallucinations_and_clusters_days(
    client, monkeypatch
) -> None:
    configure_ai(monkeypatch)
    admin = admin_headers(client)
    samal_a = create_destination(
        client,
        headers=admin,
        name="Paradise Island Samal",
        district="Davao del Norte",
        location="Samal",
        island_group="samal",
        lat=7.118,
        lng=125.676,
    )
    eden = create_destination(
        client,
        headers=admin,
        name="Eden Nature Park",
        district="Davao City",
        location="Toril",
        island_group=None,
        lat=7.032,
        lng=125.448,
    )
    hagimit = create_destination(
        client,
        headers=admin,
        name="Hagimit Falls",
        district="Davao del Norte",
        location="Samal",
        island_group="samal",
        lat=7.053,
        lng=125.704,
    )

    draft_json = json.dumps({
        "reply": "Here is a 2-day Davao & Samal plan!",
        "should_create_itinerary": True,
        "title": "Davao & Samal Escape",
        "destination": "Samal & Davao City",
        "vibe": "Beach & Mountain",
        "days_count": 2,
        "center_lat": None,
        "center_lng": None,
        "suggested_replies": ["Show stays"],
        "days": [
            {
                "day": 1,
                "title": "Day 1",
                "summary": "Mixed islands",
                "activities": [
                    {
                        "time": "08:30 AM",
                        "title": "Paradise Island Samal",
                        "description": "Beach morning",
                        "lat": None,
                        "lng": None,
                        "category": "beach",
                    },
                    {
                        "time": "12:00 PM",
                        "title": "Lunch by the water",
                        "description": "Fresh seafood lunch",
                        "lat": None,
                        "lng": None,
                        "category": "food",
                    },
                    {
                        "time": "02:00 PM",
                        "title": "Invented Secret Lagoon Atlantis",
                        "description": "Hallucinated stop",
                        "lat": 7.1,
                        "lng": 125.7,
                        "category": "sightseeing",
                    },
                    {
                        "time": "04:00 PM",
                        "title": "Eden Nature Park",
                        "description": "Cool highland pine park",
                        "lat": None,
                        "lng": None,
                        "category": "nature",
                    },
                ],
            },
            {
                "day": 2,
                "title": "Day 2",
                "summary": "Back to Samal",
                "activities": [
                    {
                        "time": "09:00 AM",
                        "title": "Hagimit Falls",
                        "description": "Cascading pools in Samal",
                        "lat": None,
                        "lng": None,
                        "category": "waterfall",
                    },
                ],
            },
        ],
    })
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([draft_json])

    response = client.post(
        "/api/v1/ai/trip-draft",
        json={"message": "Plan 2 days in Samal and Eden Nature Park"},
    )
    assert response.status_code == 200, response.text
    draft = response.json()["draft"]
    all_acts = [act for day in draft["days"] for act in day["activities"]]
    titles = [act["title"] for act in all_acts]

    # Hallucinated place dropped; grounded stops & meal kept with valid coords.
    assert "Invented Secret Lagoon Atlantis" not in titles
    assert "Paradise Island Samal" in titles
    assert "Hagimit Falls" in titles
    assert "Eden Nature Park" in titles
    for act in all_acts:
        assert act["lat"] is not None
        assert act["lng"] is not None

    # Island ping-pong repaired: Samal stops share one day cluster, Eden on another.
    day_islands = [
        {act.get("island_group") or "mainland" for act in day["activities"] if act.get("destination_id")}
        for day in draft["days"]
    ]
    assert day_islands.count({"samal"}) == 1
    assert day_islands.count({"mainland"}) == 1
    assert draft["center_lat"] is not None
    assert draft["center_lng"] is not None
    assert 6.9 < draft["center_lat"] < 7.2
    assert 125.4 < draft["center_lng"] < 125.8
    assert samal_a["destination_id"] in {a.get("destination_id") for a in all_acts}
    assert eden["destination_id"] in {a.get("destination_id") for a in all_acts}
    assert hagimit["destination_id"] in {a.get("destination_id") for a in all_acts}


def test_quality_warnings_respect_verified_opening_hours() -> None:
    verified = SimpleNamespace(
        destination_id=1,
        name="Verified Park",
        description="Nice park",
        how_to_get_there=None,
        hours_verified_at=datetime(2026, 11, 1, tzinfo=timezone.utc),
    )
    unverified = SimpleNamespace(
        destination_id=2,
        name="Unverified Falls",
        description="Nice falls",
        how_to_get_there=None,
        hours_verified_at=None,
    )
    warnings = _itinerary_quality_warnings(
        destinations=[verified, unverified],
        transportations=[],
        traveler_count=1,
        planning_preview=None,
    )
    assert not any("Verified Park" in w for w in warnings)
    assert any("Unverified Falls" in w for w in warnings)


def test_planning_state_updates_normalizes_pace_synonyms() -> None:
    from app.features.ai.schemas import AIPlanningStateUpdates

    assert AIPlanningStateUpdates(pace="Moderate").pace == "balanced"
    assert AIPlanningStateUpdates(pace="easy").pace == "relaxed"
    assert AIPlanningStateUpdates(pace="BUSY").pace == "packed"

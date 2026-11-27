import json

from tests.e2e.conftest import FakeGroqClient
from tests.e2e.helpers import (
    build_valid_itinerary_json,
    register_admin,
    register_user,
    seed_destination,
)


def test_f4_ai_chat_accepts_benign_planner_fields_cleanly(client, e2e_fakes) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    beach = seed_destination(
        client,
        admin_headers,
        name="Talikud Coral Cove",
        category="beach",
        lat=6.9333,
        lng=125.7021,
    )

    e2e_fakes.groq = FakeGroqClient(
        [
            json.dumps(
                {
                    "chat_response": "Great, keeping your beach trip moderate and quiet.",
                    "state_updates": {
                        "interests": ["beach"],
                        "activity_level": "moderate",
                        "travel_start_date": "2026-12-05",
                        "prefers_quiet": True,
                        "departure_time": "08:00",
                        "adult_count": 2,
                        "child_ages": [7],
                    },
                    "intent": "plan_trip",
                }
            )
        ]
    )

    resp = client.post(
        "/api/v1/ai/chat",
        headers=user_headers,
        json={
            "message": "Plan a quiet moderate beach trip starting Dec 5 at 8am for 2 adults and a 7yo.",
            "use_rag": False,
            "planning_state": {
                "origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128},
                "destination_ids": [beach["destination_id"]],
                "traveler_count": 3,
                "adult_count": 2,
                "child_ages": [7],
                "day_count": 2,
                "night_count": 1,
                "total_budget": "8000.00",
                "activity_level": "moderate",
                "travel_start_date": "2026-12-05",
                "prefers_quiet": True,
                "departure_time": "08:00:00",
            },
        },
    )
    assert resp.status_code == 200, resp.text
    planning = resp.json()["planning"]
    assert planning["update_status"] == "applied"
    assert "couldn't safely update" not in resp.json()["chat_response"].lower()
    state = planning["preview"]["state"]
    assert state["activity_level"] == "moderate"
    assert state["travel_start_date"] == "2026-12-05"
    assert state["prefers_quiet"] is True
    assert state["adult_count"] == 2
    assert state["child_ages"] == [7]


def test_f4_guest_ai_chat_updates_planning_state_publicly(client, e2e_fakes) -> None:
    e2e_fakes.groq = FakeGroqClient(
        [
            json.dumps(
                {
                    "chat_response": "Got it, 2 travelers for 3 days around Davao.",
                    "state_updates": {
                        "traveler_count": 2,
                        "day_count": 3,
                        "interests": ["nature"],
                    },
                    "intent": "plan_trip",
                }
            )
        ]
    )

    resp = client.post(
        "/api/v1/ai/chat/guest",
        json={
            "message": "2 people for 3 days visiting nature spots.",
            "use_rag": False,
            "planning_state": {
                "origin": {"label": "Davao City"},
            },
        },
    )
    assert resp.status_code == 200, resp.text
    planning = resp.json()["planning"]
    assert planning["update_status"] == "applied"
    state = planning["preview"]["state"]
    assert state["traveler_count"] == 2
    assert state["day_count"] == 3
    assert "nature" in [i.lower() for i in state["interests"]]


def test_f4_short_answer_followups_update_missing_details(client, e2e_fakes) -> None:
    user_headers, _ = register_user(client)

    e2e_fakes.groq = FakeGroqClient(
        [
            json.dumps(
                {
                    "chat_response": "Noted 2 adults and 1 child aged 6.",
                    "state_updates": {},
                    "intent": "plan_trip",
                }
            )
        ]
    )

    resp = client.post(
        "/api/v1/ai/chat",
        headers=user_headers,
        json={
            "message": "2 adults and 1 child age 6",
            "use_rag": False,
            "history": [
                {"role": "assistant", "content": "How many people are going?"},
            ],
            "planning_state": {
                "interests": ["beach"],
                "day_count": 3,
                "total_budget": "9000.00",
            },
        },
    )
    assert resp.status_code == 200, resp.text
    planning = resp.json()["planning"]
    assert planning["update_status"] == "applied"
    state = planning["preview"]["state"]
    assert state["adult_count"] == 2
    assert state["child_ages"] == [6]
    assert state["traveler_count"] == 3


def test_f4_multi_turn_planning_state_accumulation(client, e2e_fakes) -> None:
    user_headers, _ = register_user(client)
    e2e_fakes.groq = FakeGroqClient(
        [
            json.dumps(
                {
                    "chat_response": "Nature attractions sound great.",
                    "state_updates": {"interests": ["nature"]},
                    "intent": "plan_trip",
                }
            ),
            json.dumps(
                {
                    "chat_response": "Planning for 4 travelers over 3 days.",
                    "state_updates": {"traveler_count": 4, "day_count": 3, "night_count": 2},
                    "intent": "plan_trip",
                }
            ),
            json.dumps(
                {
                    "chat_response": "Budget set to 12000.",
                    "state_updates": {"total_budget": "12000.00"},
                    "intent": "plan_trip",
                }
            ),
        ]
    )

    # Turn 1: interests
    r1 = client.post(
        "/api/v1/ai/chat",
        headers=user_headers,
        json={"message": "We want nature spots.", "use_rag": False, "planning_state": {}},
    )
    assert r1.status_code == 200, r1.text
    assert r1.json()["planning"]["update_status"] == "applied"
    state_1 = r1.json()["planning"]["preview"]["state"]

    # Turn 2: party + days & nights
    r2 = client.post(
        "/api/v1/ai/chat",
        headers=user_headers,
        json={"message": "4 travelers for 3 days and 2 nights.", "use_rag": False, "planning_state": state_1},
    )
    assert r2.status_code == 200, r2.text
    assert r2.json()["planning"]["update_status"] == "applied"
    state_2 = r2.json()["planning"]["preview"]["state"]

    # Turn 3: budget
    r3 = client.post(
        "/api/v1/ai/chat",
        headers=user_headers,
        json={"message": "Our budget is 12000 pesos.", "use_rag": False, "planning_state": state_2},
    )
    assert r3.status_code == 200, r3.text
    assert r3.json()["planning"]["update_status"] == "applied"
    final_state = r3.json()["planning"]["preview"]["state"]

    assert final_state["interests"] == ["nature"]
    assert final_state["traveler_count"] == 4
    assert final_state["day_count"] == 3
    assert final_state["night_count"] == 2
    assert float(final_state["total_budget"]) == 12000.0


def test_f4_generate_itinerary_after_state_collected(client, e2e_fakes) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    eden = seed_destination(
        client,
        admin_headers,
        name="Eden Nature Park",
        category="mountain",
        lat=7.0320,
        lng=125.4420,
    )
    samal = seed_destination(
        client,
        admin_headers,
        name="Kaputian Beach Park",
        category="beach",
        lat=6.9701,
        lng=125.7354,
        island_group="samal",
    )

    dest_ids = [eden["destination_id"], samal["destination_id"]]
    e2e_fakes.groq = FakeGroqClient(
        [build_valid_itinerary_json(destination_ids=dest_ids, day_count=2, option_count=2)]
    )

    resp = client.post(
        "/api/v1/ai/itineraries/generate",
        headers=user_headers,
        json={
            "total_budget": "10000.00",
            "traveler_count": 2,
            "day_count": 2,
            "destination_ids": dest_ids,
            "interests": ["nature", "beach"],
            "planning_state": {
                "origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128},
                "destination_ids": dest_ids,
                "total_budget": "10000.00",
                "traveler_count": 2,
                "day_count": 2,
                "night_count": 1,
                "interests": ["nature", "beach"],
            },
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert len(body["options"]) == 2
    assert len(body["options"][0]["days"]) == 2
    assert body["planning_preview"] is not None

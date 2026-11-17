import json

import pytest

from app.integrations.groq.client import get_groq_client
from app.integrations.osrm.errors import OSRMRouteNotFoundError
from app.integrations.osrm.schemas import (
    OSRMLeg,
    OSRMRouteResult,
    OSRMTableEntry,
    OSRMTableResult,
)
from app.features.ai import service as ai_service_module
from app.features.ai import router as ai_router_module
from app.features.ai.rag import RagMatch
from tests.test_phase5_ai_itineraries import (
    FakeGroqClient,
    admin_headers,
    configure_ai,
    create_destination,
    user_headers,
)


def planning_state(destination_id: int) -> dict:
    return {
        "origin": {"label": "Davao City"},
        "destination_ids": [destination_id],
        "total_budget": "5000.00",
        "budget_scope": "whole_trip",
        "traveler_count": 2,
        "day_count": 3,
        "night_count": 2,
        "return_to_origin": True,
        "interests": ["beach"],
        "selected_transport_option_ids": ["mode:personal_vehicle"],
    }


class CandidateOSRM:
    def __init__(self, *, unreachable_lats: set[float] | None = None) -> None:
        self.unreachable_lats = unreachable_lats or set()
        self.calls = 0

    async def preview_route(self, *, travel_mode, coordinates):
        self.calls += 1
        if coordinates[-1].lat in self.unreachable_lats:
            raise OSRMRouteNotFoundError("No road route reaches this arrival point.")
        return OSRMRouteResult(
            total_distance_meters=12000,
            total_duration_seconds=1200,
            legs=[OSRMLeg(distance_meters=12000, duration_seconds=1200)],
        )

    async def table(self, *, travel_mode, origin, destinations):
        self.calls += 1
        return OSRMTableResult(
            source_snap_meters=5.0,
            entries=[
                OSRMTableEntry(duration_seconds=None, distance_meters=None, snap_meters=5.0)
                if point.lat in self.unreachable_lats
                else OSRMTableEntry(duration_seconds=1200, distance_meters=12000, snap_meters=5.0)
                for point in destinations
            ],
        )


def verified_arrival(index: int) -> dict:
    return {
        "arrival_lat": 6.95 + index * 0.001,
        "arrival_lng": 126.25,
        "arrival_source_url": "https://example.org/visitor-gate",
        "arrival_verified_at": "2026-10-29T00:00:00Z",
        "route_ready": True,
    }


def test_planning_chat_returns_grounded_candidates_without_saving_preferences(
    client,
    monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    admin = admin_headers(client)
    beaches = [
        create_destination(
            client, headers=admin, name=f"Beach {index}", **verified_arrival(index),
        )
        for index in range(6)
    ]
    create_destination(
        client,
        headers=admin,
        name="Mountain Trail",
        category="mountain",
        vibes="adventure",
        activities="hiking",
    )
    fake_client = FakeGroqClient([
        json.dumps({
            "chat_response": "I found beach matches in the catalog.",
            "state_updates": {"interests": ["beach"]},
        }),
    ])
    client.app.dependency_overrides[get_groq_client] = lambda: fake_client
    osrm = CandidateOSRM()
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: osrm)
    traveler = user_headers(client)

    response = client.post(
        "/api/v1/ai/chat",
        headers=traveler,
        json={
            "message": "Suggest beaches for me.",
            "use_rag": False,
            "input_revision": 4,
            "planning_state": {
                "origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128},
                "destination_ids": [],
                "interests": [],
                "traveler_count": 2,
                "selected_transport_option_ids": ["mode:personal_vehicle"],
            },
        },
    )

    assert response.status_code == 200
    planning = response.json()["planning"]
    assert planning["input_revision"] == 4
    assert planning["recommendation_total_candidates"] == 6
    assert len(planning["recommendations"]) == 5
    assert {item["destination_id"] for item in planning["recommendations"]} == {
        beach["destination_id"] for beach in beaches[:5]
    }
    assert all("category" in item["matched_fields"] for item in planning["recommendations"])
    assert all(item["route_provider"] == "osrm" for item in planning["recommendations"])
    assert all(item["route_verified"] for item in planning["recommendations"])
    assert all(item["travel_basis"] == "road_route" for item in planning["recommendations"])
    assert all(item["route_distance_km"] == "12.00" for item in planning["recommendations"])
    assert all(item["route_duration_minutes"] == 20 for item in planning["recommendations"])
    assert all(0 <= item["score"] <= 100 for item in planning["recommendations"])
    assert planning["recommendation_shortfall_reason"] is None
    # One travel-time table request covers every candidate.
    assert osrm.calls == 1
    assert client.get(
        "/api/v1/recommendations/preferences/latest",
        headers=traveler,
    ).status_code == 404


def test_planning_chat_puts_verified_routes_first_and_explains_skipped_places(
    client, monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    admin = admin_headers(client)
    unverified = create_destination(client, headers=admin, name="Beach Unverified")
    create_destination(client, headers=admin, name="Beach Ferry", how_to_get_there="By ferry", **verified_arrival(1))
    create_destination(client, headers=admin, name="Beach No Route", **verified_arrival(2))
    reachable = create_destination(client, headers=admin, name="Beach Reachable", **verified_arrival(3))
    create_destination(client, headers=admin, name="Mountain", category="mountain", vibes="adventure", activities="hiking")
    osrm = CandidateOSRM(unreachable_lats={verified_arrival(2)["arrival_lat"]})
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: osrm)
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([
        json.dumps({"chat_response": "Beach choices.", "state_updates": {"interests": ["beach"]}}),
    ])

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Find beaches.", "use_rag": False,
            "planning_state": {
                "origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128},
                "selected_transport_option_ids": ["mode:personal_vehicle"],
            },
        },
    )

    assert response.status_code == 200
    planning = response.json()["planning"]
    # The verified road route comes first; the unverified place fills the next
    # slot with an approximate label instead of being hidden.
    assert [item["destination_id"] for item in planning["recommendations"]] == [
        reachable["destination_id"], unverified["destination_id"],
    ]
    assert [item["route_verified"] for item in planning["recommendations"]] == [True, False]
    assert planning["recommendations"][1]["travel_basis"] == "approximate_location"
    assert planning["recommendation_total_candidates"] == 2
    assert planning["recommendation_shortfall_reason"] == (
        "Only 2 places qualify for your Top 5: 1 does not match your interests, "
        "1 needs a boat or ferry and 1 has no road route from your start."
    )
    # With cards to show, the model's reply stays and the shortfall is a note.
    assert response.json()["chat_response"] == "Beach choices."
    assert osrm.calls == 1


def test_planning_chat_does_not_fill_empty_preference_match(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    create_destination(
        client, headers=admin_headers(client), name="Mountain", category="mountain",
        vibes="adventure", activities="hiking", **verified_arrival(0),
    )
    osrm = CandidateOSRM()
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: osrm)
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([
        json.dumps({"chat_response": "I found beaches.", "state_updates": {"interests": ["beach"]}}),
    ])

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Find beaches.", "use_rag": False,
            "planning_state": {
                "origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128},
                "selected_transport_option_ids": ["mode:personal_vehicle"],
            },
        },
    )

    planning = response.json()["planning"]
    assert planning["recommendations"] == []
    assert planning["recommendation_total_candidates"] == 0
    assert "No active catalog destination matches" in planning["recommendation_shortfall_reason"]
    assert osrm.calls == 0


def test_planning_chat_without_map_origin_never_claims_a_road_route(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    beach = create_destination(client, headers=admin_headers(client), **verified_arrival(0))
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([
        json.dumps({"chat_response": "I found a beach.", "state_updates": {"interests": ["beach"]}}),
    ])

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Find beaches.", "use_rag": False,
            "planning_state": {
                "origin": {"label": "Davao City"},
                "selected_transport_option_ids": ["mode:personal_vehicle"],
            },
        },
    )

    planning = response.json()["planning"]
    [item] = planning["recommendations"]
    assert item["destination_id"] == beach["destination_id"]
    assert item["route_verified"] is False
    assert item["travel_basis"] == "unknown"
    assert item["route_duration_minutes"] is None
    assert "Set a start point to rank by travel time." in item["reasons"]
    assert planning["recommendation_shortfall_reason"] == "Only 1 place qualifies for your Top 5."
    # The model's reply is kept; the reason is shown as a note under the card.
    assert response.json()["chat_response"] == "I found a beach."


def test_planning_chat_shows_unverified_matches_with_a_label(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    beach = create_destination(client, headers=admin_headers(client), name="Beach Without Gate")
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([
        json.dumps({"chat_response": "I found a beach.", "state_updates": {"interests": ["beach"]}}),
    ])

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={"message": "Find beaches.", "use_rag": False, "planning_state": {}},
    )

    planning = response.json()["planning"]
    [item] = planning["recommendations"]
    assert item["destination_id"] == beach["destination_id"]
    assert item["route_verified"] is False
    assert planning["recommendation_total_candidates"] == 1


def test_planning_chat_applies_explicit_updates_and_returns_revision_preview(
    client,
    monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    destination = create_destination(client, headers=admin_headers(client))
    fake_client = FakeGroqClient([
        json.dumps(
            {
                "chat_response": "I updated the plan for a solo day trip.",
                "state_updates": {
                    "traveler_count": 1,
                    "day_count": 1,
                    "night_count": 0,
                    "total_budget": "6000.00",
                },
            },
        ),
    ])
    client.app.dependency_overrides[get_groq_client] = lambda: fake_client

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Make it a solo day trip with a 6000 peso budget.",
            "use_rag": False,
            "input_revision": 12,
            "planning_state": planning_state(destination["destination_id"]),
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["chat_response"] == "I updated the plan for a solo day trip."
    assert body["planning"]["input_revision"] == 12
    assert body["planning"]["update_status"] == "applied"
    assert body["planning"]["state_updates"] == {
        "traveler_count": 1,
        "day_count": 1,
        "night_count": 0,
        "total_budget": "6000.00",
    }
    preview = body["planning"]["preview"]
    assert preview["input_revision"] == 12
    assert preview["whole_trip_budget"] == "6000.00"
    assert preview["state"]["destination_ids"] == [destination["destination_id"]]
    assert preview["state"]["origin"] == {"label": "Davao City", "lat": None, "lng": None}
    assert preview["state"]["traveler_count"] == 1
    assert preview["state"]["day_count"] == 1
    assert preview["state"]["night_count"] == 0
    assert preview["state"]["selected_transport_option_ids"] == ["mode:personal_vehicle"]
    assert preview["accommodation_options"] == []

    prompt_payload = json.loads(fake_client.calls[0]["messages"][-1]["content"])
    assert prompt_payload["input_revision"] == 12
    assert prompt_payload["planning_state"]["destination_ids"] == [destination["destination_id"]]


def test_planning_chat_rejects_destination_ids_outside_catalog_context(
    client,
    monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    destination = create_destination(client, headers=admin_headers(client))
    fake_client = FakeGroqClient([
        json.dumps(
            {
                "chat_response": "I found that destination.",
                "state_updates": {"destination_ids": [999999]},
            },
        ),
    ])
    client.app.dependency_overrides[get_groq_client] = lambda: fake_client

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Change the destination.",
            "use_rag": False,
            "planning_state": planning_state(destination["destination_id"]),
        },
    )

    assert response.status_code == 200
    planning = response.json()["planning"]
    assert planning["update_status"] == "needs_clarification"
    assert planning["state_updates"] == {}
    assert planning["preview"]["state"]["destination_ids"] == [destination["destination_id"]]
    assert "kept your current destination selection" in response.json()["chat_response"]


def test_planning_chat_accepts_destination_id_from_retrieved_catalog_context(
    client,
    monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    admin = admin_headers(client)
    current_destination = create_destination(client, headers=admin, name="Current Beach")
    new_destination = create_destination(client, headers=admin, name="Matched Beach")

    async def retrieve_match(self, query, *, limit=6, history=None, context=None):
        self.coverage = {
            "status": "matched",
            "destinations": [],
            "truncated": False,
        }
        return [
            RagMatch(
                source="destination",
                source_id=new_destination["destination_id"],
                title="Matched Beach",
                score=1.0,
                payload={"destination_id": new_destination["destination_id"]},
            ),
        ]

    monkeypatch.setattr(ai_service_module.VectorRAGRetriever, "retrieve", retrieve_match)
    fake_client = FakeGroqClient([
        json.dumps(
            {
                "chat_response": "I matched the new destination in the catalog.",
                "state_updates": {"destination_ids": [new_destination["destination_id"]]},
            },
        ),
    ])
    client.app.dependency_overrides[get_groq_client] = lambda: fake_client

    previous_state = planning_state(current_destination["destination_id"])
    previous_state["adult_count"] = 1
    previous_state["child_ages"] = [8]
    previous_state["age_pricing_rules"] = [
        {
            "category": "destination",
            "reference_id": f"destination:{current_destination['destination_id']}",
            "adult_unit_amount": "200.00",
            "child_bands": [{"min_age": 8, "max_age": 8, "rate": "half"}],
        },
    ]
    previous_state["cost_allowances"] = [
        {
            "category": "destination",
            "destination_id": current_destination["destination_id"],
            "amount": "200.00",
        },
    ]

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Change to Matched Beach.",
            "planning_state": previous_state,
        },
    )

    assert response.status_code == 200
    planning = response.json()["planning"]
    assert planning["update_status"] == "applied"
    assert planning["state_updates"] == {
        "destination_ids": [new_destination["destination_id"]],
    }
    assert planning["preview"]["state"]["destination_ids"] == [
        new_destination["destination_id"],
    ]
    assert planning["preview"]["state"]["selected_transport_option_ids"] == []
    assert planning["preview"]["state"]["cost_allowances"] == []
    assert planning["preview"]["state"]["age_pricing_rules"] == []
    assert planning["preview"]["state"]["child_ages"] == [8]


def test_planning_chat_origin_label_update_clears_stale_coordinates_and_road_confirmation(
    client,
    monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    destination = create_destination(client, headers=admin_headers(client))
    state = planning_state(destination["destination_id"])
    state["origin"] = {"label": "Davao City", "lat": 7.0731, "lng": 125.6128}
    state["route_preferences"] = {"road_access_confirmed": True}
    fake_client = FakeGroqClient([
        json.dumps(
            {
                "chat_response": "I changed the starting point to Mati City.",
                "state_updates": {"origin": {"label": "Mati City"}},
            },
        ),
    ])
    client.app.dependency_overrides[get_groq_client] = lambda: fake_client

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Start from Mati City instead.",
            "use_rag": False,
            "planning_state": state,
        },
    )

    assert response.status_code == 200
    planning = response.json()["planning"]
    preview_state = planning["preview"]["state"]
    assert preview_state["origin"] == {"label": "Mati City", "lat": None, "lng": None}
    assert preview_state["route_preferences"] is None
    assert planning["state_updates"]["route_preferences"] is None


def test_planning_chat_recovers_valid_fields_when_origin_has_wrong_shape(
    client,
    monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    destination = create_destination(client, headers=admin_headers(client))
    fake_client = FakeGroqClient([json.dumps({
        "chat_response": "I saved the new origin and your full plan.",
        "state_updates": {
            "origin": "Mati City",
            "total_budget": 6000,
            "traveler_count": 1,
            "day_count": 2,
        },
    })])
    client.app.dependency_overrides[get_groq_client] = lambda: fake_client

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Start from Mati City, make it a two-day solo trip for 6000 pesos.",
            "use_rag": False,
            "planning_state": planning_state(destination["destination_id"]),
        },
    )

    assert response.status_code == 200
    body = response.json()
    planning = body["planning"]
    assert planning["update_status"] == "applied"
    assert planning["state_updates"] == {
        "total_budget": "6000",
        "traveler_count": 1,
        "day_count": 2,
    }
    state = planning["preview"]["state"]
    assert state["origin"] == {"label": "Davao City", "lat": None, "lng": None}
    assert state["total_budget"] == "6000"
    assert state["traveler_count"] == 1
    assert state["day_count"] == 2
    assert "couldn't save your starting place" in body["chat_response"]
    assert "I saved the new origin" not in body["chat_response"]
    prompt = fake_client.calls[0]["messages"][0]["content"]
    assert '{"origin":{"label":"Davao City"}}' in prompt
    assert "Never infer night_count from day_count alone" in prompt


def test_planning_chat_recovers_budget_but_rejects_bad_destination_field(
    client,
    monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    destination = create_destination(client, headers=admin_headers(client))
    fake_client = FakeGroqClient([json.dumps({
        "chat_response": "I chose a different destination.",
        "state_updates": {
            "destination_ids": ["not-an-id"],
            "total_budget": 7000,
        },
    })])
    client.app.dependency_overrides[get_groq_client] = lambda: fake_client

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Try somewhere else, with a 7000 peso budget.",
            "use_rag": False,
            "planning_state": planning_state(destination["destination_id"]),
        },
    )

    assert response.status_code == 200
    planning = response.json()["planning"]
    assert planning["update_status"] == "applied"
    assert planning["state_updates"] == {"total_budget": "7000"}
    assert planning["preview"]["state"]["destination_ids"] == [
        destination["destination_id"],
    ]
    assert "couldn't save your destination" in response.json()["chat_response"]


def test_planning_chat_rejects_inferred_night_and_return_details(
    client,
    monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    destination = create_destination(client, headers=admin_headers(client))
    state = planning_state(destination["destination_id"])
    state.pop("night_count")
    state.pop("return_to_origin")
    fake_client = FakeGroqClient([json.dumps({
        "chat_response": "I set one night and a return trip.",
        "state_updates": {
            "total_budget": 6000,
            "night_count": 1,
            "return_to_origin": True,
        },
    })])
    client.app.dependency_overrides[get_groq_client] = lambda: fake_client

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Plan a two-day solo trip for 6000 pesos.",
            "use_rag": False,
            "planning_state": state,
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["planning"]["update_status"] == "applied"
    assert body["planning"]["state_updates"] == {"total_budget": "6000"}
    next_state = body["planning"]["preview"]["state"]
    assert next_state["night_count"] is None
    assert next_state["return_to_origin"] is None
    # The guess is not claimed as saved, and nothing is blamed on the traveler.
    assert "overnight stay" in body["chat_response"]
    assert "whether you'll return to Davao City" in body["chat_response"]
    assert "I set one night" not in body["chat_response"]
    assert "could not use" not in body["chat_response"]


@pytest.mark.parametrize(
    ("message", "night_count", "return_to_origin"),
    [
        ("Make it two days, one night, and a round trip.", 1, True),
        ("Make it a day trip, one way.", 0, False),
        ("We are not staying overnight and not returning to Davao City.", 0, False),
    ],
)
def test_planning_chat_accepts_explicit_night_and_return_details(
    client,
    monkeypatch,
    message,
    night_count,
    return_to_origin,
) -> None:
    configure_ai(monkeypatch)
    destination = create_destination(client, headers=admin_headers(client))
    state = planning_state(destination["destination_id"])
    state.pop("night_count")
    state.pop("return_to_origin")
    fake_client = FakeGroqClient([json.dumps({
        "chat_response": "I updated those trip details.",
        "state_updates": {
            "night_count": night_count,
            "return_to_origin": return_to_origin,
        },
    })])
    client.app.dependency_overrides[get_groq_client] = lambda: fake_client

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": message,
            "use_rag": False,
            "planning_state": state,
        },
    )

    assert response.status_code == 200
    assert response.json()["planning"]["state_updates"] == {
        "night_count": night_count,
        "return_to_origin": return_to_origin,
    }


def test_planning_chat_does_not_warn_when_model_repeats_existing_trip_details(
    client,
    monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    destination = create_destination(client, headers=admin_headers(client))
    fake_client = FakeGroqClient([json.dumps({
        "chat_response": "What else would you like to change?",
        "state_updates": {"night_count": 2, "return_to_origin": True},
    })])
    client.app.dependency_overrides[get_groq_client] = lambda: fake_client

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "What activities are nearby?",
            "use_rag": False,
            "planning_state": planning_state(destination["destination_id"]),
        },
    )

    assert response.status_code == 200
    assert response.json()["planning"]["update_status"] == "no_changes"
    assert response.json()["chat_response"] == "What else would you like to change?"


def test_planning_chat_does_not_choose_between_ambiguous_trip_details(
    client,
    monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    destination = create_destination(client, headers=admin_headers(client))
    state = planning_state(destination["destination_id"])
    state.pop("night_count")
    state.pop("return_to_origin")
    fake_client = FakeGroqClient([json.dumps({
        "chat_response": "I chose one night and a return trip.",
        "state_updates": {"night_count": 1, "return_to_origin": True},
    })])
    client.app.dependency_overrides[get_groq_client] = lambda: fake_client

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Maybe one night or two nights, and round trip or one way.",
            "use_rag": False,
            "planning_state": state,
        },
    )

    assert response.status_code == 200
    assert response.json()["planning"]["state_updates"] == {}
    assert response.json()["planning"]["preview"]["state"]["night_count"] is None
    assert response.json()["planning"]["preview"]["state"]["return_to_origin"] is None
    assert "I chose one night" not in response.json()["chat_response"]


def test_planning_chat_rejects_model_echo_when_traveler_changes_nights(
    client,
    monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    destination = create_destination(client, headers=admin_headers(client))
    fake_client = FakeGroqClient([json.dumps({
        "chat_response": "I changed it to one night.",
        "state_updates": {"night_count": 2},
    })])
    client.app.dependency_overrides[get_groq_client] = lambda: fake_client

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Change to one night.",
            "use_rag": False,
            "planning_state": planning_state(destination["destination_id"]),
        },
    )

    assert response.status_code == 200
    assert response.json()["planning"]["state_updates"] == {}
    assert response.json()["planning"]["preview"]["state"]["night_count"] == 2
    assert "I changed it to one night" not in response.json()["chat_response"]


@pytest.mark.parametrize(
    ("message", "question", "updates"),
    [
        ("one", "How many nights will you stay?", {"night_count": 1}),
        ("yes", "Will you return to Davao City?", {"return_to_origin": True}),
    ],
)
def test_planning_chat_accepts_short_answers_to_specific_questions(
    client,
    monkeypatch,
    message,
    question,
    updates,
) -> None:
    configure_ai(monkeypatch)
    destination = create_destination(client, headers=admin_headers(client))
    state = planning_state(destination["destination_id"])
    state.pop("night_count")
    state.pop("return_to_origin")
    fake_client = FakeGroqClient([json.dumps({
        "chat_response": "I added that detail.",
        "state_updates": updates,
    })])
    client.app.dependency_overrides[get_groq_client] = lambda: fake_client

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": message,
            "history": [{"role": "assistant", "content": question}],
            "use_rag": False,
            "planning_state": state,
        },
    )

    assert response.status_code == 200
    assert response.json()["planning"]["state_updates"] == updates


def test_planning_chat_invalid_structured_output_keeps_current_preview(
    client,
    monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    destination = create_destination(client, headers=admin_headers(client))
    fake_client = FakeGroqClient(["This is not the required JSON object."])
    client.app.dependency_overrides[get_groq_client] = lambda: fake_client

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Make it one day.",
            "use_rag": False,
            "input_revision": 3,
            "planning_state": planning_state(destination["destination_id"]),
        },
    )

    assert response.status_code == 200
    body = response.json()
    assert body["planning"]["update_status"] == "invalid_output"
    assert body["planning"]["state_updates"] == {}
    assert body["planning"]["preview"]["input_revision"] == 3
    assert body["planning"]["preview"]["state"]["day_count"] == 3
    assert body["planning"]["preview"]["state"]["destination_ids"] == [
        destination["destination_id"],
    ]


def test_planning_chat_rejects_model_changes_to_preview_selections(
    client,
    monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    destination = create_destination(client, headers=admin_headers(client))
    fake_client = FakeGroqClient([
        json.dumps(
            {
                "chat_response": "I chose the transport for you.",
                "state_updates": {
                    "selected_transport_option_ids": [],
                    "total_budget": 7000,
                },
            },
        ),
    ])
    client.app.dependency_overrides[get_groq_client] = lambda: fake_client

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Make it cheaper.",
            "use_rag": False,
            "planning_state": planning_state(destination["destination_id"]),
        },
    )

    assert response.status_code == 200
    planning = response.json()["planning"]
    assert planning["update_status"] == "invalid_output"
    assert planning["state_updates"] == {}
    assert planning["preview"]["state"]["selected_transport_option_ids"] == [
        "mode:personal_vehicle",
    ]
    assert planning["preview"]["state"]["total_budget"] == "5000.00"


def _named_place_chat(client, message, reply):
    admin = admin_headers(client)
    samal = create_destination(
        client, headers=admin, name="Samal Island Beach", location="Samal Island",
        district="Davao del Norte", **verified_arrival(0),
    )
    samal_two = create_destination(
        client, headers=admin, name="Samal Pearl Farm", location="Samal Island",
        district="Davao del Norte", **verified_arrival(2),
    )
    create_destination(
        client, headers=admin, name="Mati Rock Beach", location="Mati City",
        district="Davao Oriental", **verified_arrival(1),
    )
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([
        json.dumps({"chat_response": reply, "state_updates": {}}),
    ])
    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": message,
            "use_rag": True,
            "planning_state": {"origin": {"label": "Davao City"}},
        },
    )
    assert response.status_code == 200
    return (samal, samal_two), response.json()


def test_named_place_without_interests_offers_selectable_cards(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    (samal, samal_two), body = _named_place_chat(
        client, "I want to go to Samal Island", "Samal has a few spots.",
    )

    planning = body["planning"]
    # Two Samal places match equally, so nothing is guessed: the traveler gets cards.
    assert planning["state_updates"] == {}
    assert {item["destination_id"] for item in planning["recommendations"]} == {
        samal["destination_id"], samal_two["destination_id"],
    }
    assert planning["recommendation_total_candidates"] == 2
    assert planning["recommendation_shortfall_reason"] is None
    # The model's own reply is kept, not replaced by a ranking message.
    assert body["chat_response"] == "Samal has a few spots."


def test_greeting_without_a_named_place_offers_no_cards(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    _, body = _named_place_chat(client, "hello there", "Hi! Where would you like to go?")

    planning = body["planning"]
    assert planning["recommendations"] == []
    assert planning["recommendation_shortfall_reason"] == (
        "No travel interests were supplied, so there is no preference match to rank."
    )


def test_interest_detected_in_the_message_ranks_when_model_omits_it(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    admin = admin_headers(client)
    beach = create_destination(client, headers=admin, name="Beach One", **verified_arrival(0))
    create_destination(
        client, headers=admin, name="Mountain", category="mountain",
        vibes="adventure", activities="hiking", **verified_arrival(1),
    )
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([
        # The model forgot to record the interest the traveler stated.
        json.dumps({"chat_response": "Here are some ideas.", "state_updates": {}}),
    ])

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Find me beaches in Davao",
            "use_rag": True,
            "planning_state": {
                "origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128},
                "selected_transport_option_ids": ["mode:personal_vehicle"],
            },
        },
    )

    assert response.status_code == 200, response.text
    planning = response.json()["planning"]
    assert [item["destination_id"] for item in planning["recommendations"]] == [
        beach["destination_id"],
    ]
    assert planning["state_updates"] == {}  # the saved plan is not changed by the fallback


def test_a_nature_request_returns_cards_for_nature_places(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    admin = admin_headers(client)
    park = create_destination(
        client, headers=admin, name="Green Park", category="park",
        vibes="nature, relaxing", activities="walking", **verified_arrival(0),
    )
    mountain = create_destination(
        client, headers=admin, name="Mountain", category="mountain",
        vibes="adventure", activities="hiking", **verified_arrival(1),
    )
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([
        json.dumps({"chat_response": "Here are some ideas.", "state_updates": {}}),
    ])

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Show me nature spots in Davao",
            "use_rag": True,
            "planning_state": {
                "origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128},
                "selected_transport_option_ids": ["mode:personal_vehicle"],
            },
        },
    )

    assert response.status_code == 200, response.text
    planning = response.json()["planning"]
    # "nature" is the Nature attractions group: a mountain is nature, and a park
    # whose vibes say nature still matches by its text.
    assert {item["destination_id"] for item in planning["recommendations"]} == {
        park["destination_id"], mountain["destination_id"],
    }


def test_more_places_can_be_offered_after_a_stop_is_selected(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    admin = admin_headers(client)
    first = create_destination(client, headers=admin, name="Beach One", **verified_arrival(0))
    second = create_destination(client, headers=admin, name="Beach Two", **verified_arrival(1))
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([
        json.dumps({"chat_response": "Here are more beaches.", "state_updates": {}}),
    ])

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Find me more beaches in Davao",
            "use_rag": True,
            "planning_state": {
                "origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128},
                "destination_ids": [first["destination_id"]],
                "selected_transport_option_ids": ["mode:personal_vehicle"],
            },
        },
    )

    assert response.status_code == 200, response.text
    planning = response.json()["planning"]
    ids = [item["destination_id"] for item in planning["recommendations"]]
    assert second["destination_id"] in ids
    assert first["destination_id"] not in ids
    assert response.json()["chat_response"] == "Here are more beaches."


def _named_chat(client, message, *, destinations, model_reply, planning_state=None):
    admin = admin_headers(client)
    created = {
        name: create_destination(client, headers=admin, name=name, **verified_arrival(i))
        for i, name in enumerate(destinations)
    }
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([model_reply])
    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": message,
            "use_rag": True,
            "planning_state": planning_state or {"origin": {"label": "Davao City"}},
        },
    )
    assert response.status_code == 200, response.text
    return created, response.json()


CAUTIOUS_REPLY = json.dumps({
    "chat_response": "Great choice! Where will you start, and how many travelers?",
    "state_updates": {},
})


def test_a_named_destination_is_added_even_when_the_model_only_asks_questions(
    client, monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    created, body = _named_chat(
        client, "I like to go to bemwa",
        destinations=["Bemwa Farm", "Mati Rock Beach"], model_reply=CAUTIOUS_REPLY,
    )

    farm_id = created["Bemwa Farm"]["destination_id"]
    planning = body["planning"]
    assert planning["state_updates"] == {"destination_ids": [farm_id]}
    assert planning["update_status"] == "applied"
    assert [d["name"] for d in planning["preview"]["destinations"]] == ["Bemwa Farm"]
    assert body["chat_response"].startswith("Great choice! Where will you start")
    assert body["chat_response"].endswith("I added Bemwa Farm to your plan.")
    assert planning["recommendations"] == []  # nothing left to choose


def test_a_named_destination_is_added_even_when_the_model_output_is_unusable(
    client, monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    created, body = _named_chat(
        client, "I like to go to bemwa",
        destinations=["Bemwa Farm"], model_reply="Sorry, this is not JSON at all.",
    )

    planning = body["planning"]
    assert planning["state_updates"] == {
        "destination_ids": [created["Bemwa Farm"]["destination_id"]],
    }
    assert planning["update_status"] == "applied"
    assert "I added Bemwa Farm to your plan." in body["chat_response"]


def test_equally_good_matches_become_cards_instead_of_a_guess(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    created, body = _named_chat(
        client, "I want to see Uraya",
        destinations=["Uraya's Peak Adventure Park", "Uraya Falls", "Mati Rock Beach"],
        model_reply=CAUTIOUS_REPLY,
    )

    planning = body["planning"]
    assert planning["state_updates"] == {}
    assert {item["destination_id"] for item in planning["recommendations"]} == {
        created["Uraya's Peak Adventure Park"]["destination_id"],
        created["Uraya Falls"]["destination_id"],
    }
    assert "I added" not in body["chat_response"]


def test_a_negated_request_neither_adds_nor_offers_the_place(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    _, body = _named_chat(
        client, "I don't want to go to bemwa",
        destinations=["Bemwa Farm"], model_reply=CAUTIOUS_REPLY,
    )

    planning = body["planning"]
    assert planning["state_updates"] == {}
    assert planning["recommendations"] == []
    assert "I added" not in body["chat_response"]


def test_an_already_chosen_destination_is_not_replaced_by_a_mention(
    client, monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    admin = admin_headers(client)
    chosen = create_destination(client, headers=admin, name="Eden Nature Park", **verified_arrival(0))
    create_destination(client, headers=admin, name="Bemwa Farm", **verified_arrival(1))
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([CAUTIOUS_REPLY])

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "What about bemwa?",
            "use_rag": True,
            "planning_state": {
                "origin": {"label": "Davao City"},
                "destination_ids": [chosen["destination_id"]],
            },
        },
    )

    assert response.status_code == 200, response.text
    planning = response.json()["planning"]
    assert planning["state_updates"] == {}
    assert [d["name"] for d in planning["preview"]["destinations"]] == ["Eden Nature Park"]


def test_double_escaped_line_breaks_in_the_reply_become_real_line_breaks(
    client, monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    _, body = _named_chat(
        client, "hello there", destinations=["Bemwa Farm"],
        model_reply=json.dumps({
            # A literal backslash followed by "n", as some models emit it.
            "chat_response": "Great!\\n- Where from?\\n- How many travelers?",
            "state_updates": {},
        }),
    )

    assert body["chat_response"] == "Great!\n- Where from?\n- How many travelers?"
    assert "\\n" not in body["chat_response"]


@pytest.mark.parametrize(
    "extra,expected_intent,expected_replies",
    [
        (
            {"intent": "logistics",
             "suggested_replies": ["  How much is the barge?  ", "", "x" * 120, "Any pump boats?",
                                   "Best time to go?", "Fourth"]},
            "logistics",
            ["How much is the barge?", "Any pump boats?", "Best time to go?"],
        ),
        ({"intent": "teleport", "suggested_replies": "not a list"}, None, []),
        ({}, None, []),
    ],
)
def test_planning_chat_returns_model_intent_and_clean_suggested_replies(
    client, monkeypatch, extra, expected_intent, expected_replies,
) -> None:
    configure_ai(monkeypatch)
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([
        json.dumps({
            "chat_response": "Take the RoRo barge from Sasa Wharf; it runs often in daytime.",
            "state_updates": {},
            **extra,
        }),
    ])

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "How do I bring my car to Samal?", "use_rag": False,
            "planning_state": {"origin": {"label": "Davao City"}},
        },
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["chat_response"].startswith("Take the RoRo barge")
    assert body["planning"]["intent"] == expected_intent
    assert body["planning"]["suggested_replies"] == expected_replies


def test_show_places_mountain_plus_province_filters_by_region_xi_province(
    client, monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    admin = admin_headers(client)
    # Davao de Oro mountain (7.285, 125.95 - inside Davao de Oro polygon)
    oro_mountain = create_destination(
        client, headers=admin, name="Maragusan Peak",
        category="Mountain", vibes="hiking,nature", activities="trekking",
        district="Maragusan", lat=7.30, lng=126.15,
    )
    # Davao de Oro beach (must be filtered out by category)
    create_destination(
        client, headers=admin, name="Kopiat Cove",
        category="Beach", vibes="island", activities="swimming",
        district="Mabini", lat=7.277, lng=125.832,
    )
    # Davao Oriental mountain (must be filtered out by province)
    create_destination(
        client, headers=admin, name="Mt. Hamiguitan",
        category="Mountain", vibes="hiking,unesco", activities="trekking",
        district="San Isidro", lat=6.74, lng=126.18,
    )
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([
        json.dumps({
            "chat_response": "Here are mountains in Davao de Oro.",
            "state_updates": {},
            "intent": "show_places",
            "place_query": {
                "categories": ["mountains"],
                "province": "Davao de Oro",
                "limit": 5,
            },
        }),
    ])

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Show me mountains in Davao de Oro",
            "use_rag": False,
            "planning_state": {
                # Traveler GPS is Davao City; named province in query must win.
                "origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128},
            },
        },
    )

    assert response.status_code == 200, response.text
    planning = response.json()["planning"]
    assert planning["intent"] == "show_places"
    assert [item["destination_id"] for item in planning["recommendations"]] == [
        oro_mountain["destination_id"],
    ]
    assert planning["recommendation_shortfall_reason"] is not None
    assert "Davao de Oro" in planning["recommendation_shortfall_reason"]
    assert "Davao Oriental" in planning["recommendation_shortfall_reason"]


def test_show_places_without_province_uses_gps_province(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    admin = admin_headers(client)
    mati_beach = create_destination(
        client, headers=admin, name="Dahican Surf Coast",
        category="Beach", vibes="surf,beach", activities="surfing",
        district="Mati", lat=6.95, lng=126.22,
    )
    create_destination(
        client, headers=admin, name="Samal White Shore",
        category="Beach", vibes="island", activities="swimming",
        district="Samal", lat=7.087, lng=125.667,
    )
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([
        json.dumps({
            "chat_response": "Beaches near you.",
            "state_updates": {},
            "intent": "show_places",
            "place_query": {"categories": ["beach"], "limit": 5},
        }),
    ])

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Show me beaches near me",
            "use_rag": False,
            "planning_state": {
                # Current GPS in Mati (Davao Oriental)
                "origin": {"label": "Mati", "lat": 6.95, "lng": 126.22},
            },
        },
    )

    assert response.status_code == 200, response.text
    planning = response.json()["planning"]
    assert [item["destination_id"] for item in planning["recommendations"]] == [
        mati_beach["destination_id"],
    ]


def test_show_places_empty_match_gives_honest_message_without_padding(
    client, monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    admin = admin_headers(client)
    create_destination(
        client, headers=admin, name="Hamiguitan Ridge",
        category="Mountain", vibes="hiking", activities="trekking",
        district="San Isidro", lat=6.74, lng=126.18,
    )
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([
        json.dumps({
            "chat_response": "Check out these mountains in Davao Occidental!",
            "state_updates": {},
            "intent": "show_places",
            "place_query": {
                "categories": ["mountain"],
                "province": "Davao Occidental",
                "limit": 5,
            },
        }),
    ])

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Show me mountains in Davao Occidental",
            "use_rag": False,
            "planning_state": {"origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128}},
        },
    )

    assert response.status_code == 200, response.text
    body = response.json()
    planning = body["planning"]
    assert planning["recommendations"] == []
    assert "Davao Occidental" in planning["recommendation_shortfall_reason"]
    assert "Davao Oriental" in planning["recommendation_shortfall_reason"]
    assert body["chat_response"] == planning["recommendation_shortfall_reason"]


def test_show_places_general_browse_and_plain_question_card_behavior(
    client, monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    admin = admin_headers(client)
    davao_park = create_destination(
        client, headers=admin, name="People's Park Davao",
        category="Park", vibes="city,family", activities="walking",
        district="Davao City", lat=7.07, lng=125.61,
    )
    fake_client = FakeGroqClient([
        json.dumps({
            "chat_response": "Here are Davao City places.",
            "state_updates": {},
            "intent": "show_places",
            "place_query": {"categories": [], "limit": 5},
        }),
        json.dumps({
            "chat_response": "December is mostly pleasant with light showers.",
            "state_updates": {},
            "intent": "question",
        }),
    ])
    client.app.dependency_overrides[get_groq_client] = lambda: fake_client

    traveler = user_headers(client)
    browse = client.post(
        "/api/v1/ai/chat",
        headers=traveler,
        json={
            "message": "Show me destinations",
            "use_rag": False,
            "planning_state": {"origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128}},
        },
    )
    assert browse.status_code == 200
    assert [r["destination_id"] for r in browse.json()["planning"]["recommendations"]] == [
        davao_park["destination_id"],
    ]

    question = client.post(
        "/api/v1/ai/chat",
        headers=traveler,
        json={
            "message": "Is December good for Davao?",
            "use_rag": False,
            "planning_state": {"origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128}},
        },
    )
    assert question.status_code == 200
    assert question.json()["planning"]["intent"] == "question"
    assert question.json()["planning"]["recommendations"] == []


# --- Cards after stops are picked: a named place wins, picks never come back ---


def _picked_chat(client, message, *, picked, others, reply=CAUTIOUS_REPLY):
    """A chat where `picked` are already in the plan and `others` are in the catalog."""
    admin = admin_headers(client)
    index = 0
    created = {}
    for name, extra in [*picked, *others]:
        created[name] = create_destination(
            client, headers=admin, name=name, **extra, **verified_arrival(index),
        )
        index += 1
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([reply])
    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": message,
            "use_rag": True,
            "planning_state": {
                "origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128},
                "destination_ids": [created[name]["destination_id"] for name, _ in picked],
                "selected_transport_option_ids": ["mode:personal_vehicle"],
            },
        },
    )
    assert response.status_code == 200, response.text
    return created, response.json()


MUSEUM = {"category": "museum", "vibes": "culture", "activities": "museum visit"}
BEACH = {"category": "beach"}


def test_an_explicit_add_puts_the_named_museum_in_the_plan(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    created, body = _picked_chat(
        client, "Please add the National Museum",
        picked=[("Beach A", BEACH), ("Beach B", BEACH), ("Beach C", BEACH)],
        others=[("National Museum of the Philippines - Davao", MUSEUM),
                ("Museo Dabawenyo", MUSEUM), ("Subangan Museum", MUSEUM)],
    )

    planning = body["planning"]
    museum_id = created["National Museum of the Philippines - Davao"]["destination_id"]
    picked_ids = [created[n]["destination_id"] for n in ("Beach A", "Beach B", "Beach C")]
    assert planning["update_status"] == "applied"
    assert planning["state_updates"]["destination_ids"] == [*picked_ids, museum_id]
    assert planning["recommendations"] == []  # nothing left to choose
    assert body["chat_response"].startswith(
        "Added National Museum of the Philippines - Davao: that makes 4 stops",
    )


def test_naming_a_place_without_asking_to_add_offers_just_that_card(
    client, monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    created, body = _picked_chat(
        client, "What about the National Museum?",
        picked=[("Beach A", BEACH), ("Beach B", BEACH), ("Beach C", BEACH)],
        others=[("National Museum of the Philippines - Davao", MUSEUM),
                ("Museo Dabawenyo", MUSEUM), ("Subangan Museum", MUSEUM)],
    )

    planning = body["planning"]
    assert planning["state_updates"] == {}
    # One card, the place named; not five museum cards.
    assert [c["destination_id"] for c in planning["recommendations"]] == [
        created["National Museum of the Philippines - Davao"]["destination_id"],
    ]


def test_more_of_a_kind_after_picks_shows_a_short_list_without_the_picks(
    client, monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    created, body = _picked_chat(
        client, "Show me more beaches",
        picked=[("Beach A", BEACH), ("Beach B", BEACH), ("Beach C", BEACH)],
        others=[(f"Shore {i}", BEACH) for i in range(6)],
        reply=json.dumps({"chat_response": "More beaches for you.", "state_updates": {}}),
    )

    ids = [c["destination_id"] for c in body["planning"]["recommendations"]]
    picked_ids = {created[n]["destination_id"] for n in ("Beach A", "Beach B", "Beach C")}
    assert 1 <= len(ids) <= 3
    assert not set(ids) & picked_ids


def test_show_places_never_lists_a_place_already_picked(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    created, body = _picked_chat(
        client, "Show me beaches",
        picked=[("Beach A", BEACH)],
        others=[("Beach B", BEACH), ("Beach C", BEACH)],
        reply=json.dumps({
            "chat_response": "Here are beaches.", "state_updates": {},
            "intent": "show_places", "place_query": {"categories": ["beach"], "limit": 5},
        }),
    )

    ids = {c["destination_id"] for c in body["planning"]["recommendations"]}
    assert created["Beach A"]["destination_id"] not in ids
    assert ids == {created["Beach B"]["destination_id"], created["Beach C"]["destination_id"]}


def test_a_refused_model_id_does_not_contradict_the_name_based_add(
    client, monkeypatch,
) -> None:
    """Live case: the model named the museum with an id outside the context, the
    server refused that id, then added the museum by name. The reply must not say
    it could not match, and earlier "beaches" talk must not bring beach cards back."""
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    admin = admin_headers(client)
    picked = create_destination(
        client, headers=admin, name="Beach A", category="beach", **verified_arrival(0),
    )
    for i in range(1, 4):
        create_destination(
            client, headers=admin, name=f"Shore {i}", category="beach", **verified_arrival(i),
        )
    museum = create_destination(
        client, headers=admin, name="National Museum of the Philippines - Davao",
        **MUSEUM, **verified_arrival(9),
    )
    reply = json.dumps({
        "chat_response": "Added the National Museum: that makes two stops.",
        "state_updates": {"destination_ids": [picked["destination_id"], 999999]},
        "intent": "modify_trip",
    })
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([reply])

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "add the National Museum",
            "use_rag": True,
            "history": [
                {"role": "user", "content": "show me beach resorts"},
                {"role": "assistant", "content": "Here are some beach resorts."},
            ],
            "planning_state": {
                "origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128},
                "destination_ids": [picked["destination_id"]],
                "interests": ["beach"],
                "selected_transport_option_ids": ["mode:personal_vehicle"],
            },
        },
    )

    assert response.status_code == 200, response.text
    body = response.json()
    planning = body["planning"]
    assert planning["state_updates"]["destination_ids"] == [
        picked["destination_id"], museum["destination_id"],
    ]
    assert "couldn't match" not in body["chat_response"]
    assert body["chat_response"].startswith(
        "Added National Museum of the Philippines - Davao: that makes 2 stops",
    )
    assert planning["recommendations"] == []


def test_a_wrong_place_proposed_by_the_model_is_not_added(client, monkeypatch) -> None:
    """Live case: the traveler said "add the National Museum"; the model wrote
    "Added Dahican Surf Resort" and put Dahican's id in the plan. Only the place the
    traveler named is added, and the reply names it."""
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    admin = admin_headers(client)
    picked = create_destination(
        client, headers=admin, name="Lanikai Hijo Estate Resort", category="beach",
        **verified_arrival(0),
    )
    wrong = create_destination(
        client, headers=admin, name="Dahican Surf Resort", category="beach",
        **verified_arrival(1),
    )
    museum = create_destination(
        client, headers=admin, name="National Museum of the Philippines - Davao",
        **MUSEUM, **verified_arrival(2),
    )
    reply = json.dumps({
        "chat_response": "Added Dahican Surf Resort: that makes two stops now.",
        "state_updates": {
            "destination_ids": [picked["destination_id"], wrong["destination_id"]],
        },
        "intent": "modify_trip",
    })
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([reply])

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "add the National Museum",
            "use_rag": True,
            "planning_state": {
                "origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128},
                "destination_ids": [picked["destination_id"]],
                "selected_transport_option_ids": ["mode:personal_vehicle"],
            },
        },
    )

    assert response.status_code == 200, response.text
    body = response.json()
    planning = body["planning"]
    assert planning["state_updates"]["destination_ids"] == [
        picked["destination_id"], museum["destination_id"],
    ]
    assert "Dahican" not in body["chat_response"]
    assert body["chat_response"] == (
        "Added National Museum of the Philippines - Davao: that makes 2 stops in your "
        "plan (Lanikai Hijo Estate Resort, National Museum of the Philippines - Davao). "
        "Want to add more or start planning?"
    )
    assert [d["destination_id"] for d in planning["preview"]["destinations"]] == [
        picked["destination_id"], museum["destination_id"],
    ]


def _add_museum_chat(client, monkeypatch, model_reply):
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    admin = admin_headers(client)
    picked = create_destination(
        client, headers=admin, name="Lanikai Hijo Estate Resort", category="beach",
        **verified_arrival(0),
    )
    museum = create_destination(
        client, headers=admin, name="National Museum of the Philippines - Davao",
        **MUSEUM, **verified_arrival(1),
    )
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([model_reply])
    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "add the National Museum",
            "use_rag": True,
            "planning_state": {
                "origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128},
                "destination_ids": [picked["destination_id"]],
                "selected_transport_option_ids": ["mode:personal_vehicle"],
            },
        },
    )
    assert response.status_code == 200, response.text
    return picked, museum, response.json()


def test_an_explicit_add_works_even_when_the_model_calls_it_a_question(
    client, monkeypatch,
) -> None:
    """Live case: the model answered "add the National Museum" as a question and said
    the museum was outside the region. The traveler's words win over that label."""
    reply = json.dumps({
        "chat_response": "National Museum is located outside the Davao Region.",
        "state_updates": {},
        "intent": "question",
    })
    picked, museum, body = _add_museum_chat(client, monkeypatch, reply)

    planning = body["planning"]
    assert planning["state_updates"]["destination_ids"] == [
        picked["destination_id"], museum["destination_id"],
    ]
    assert planning["update_status"] == "applied"
    assert "outside" not in body["chat_response"]
    assert body["chat_response"].startswith(
        "Added National Museum of the Philippines - Davao: that makes 2 stops",
    )
    assert planning["recommendations"] == []


def test_an_explicit_add_works_when_the_model_labels_it_show_places(
    client, monkeypatch,
) -> None:
    reply = json.dumps({
        "chat_response": "Here are some museums.",
        "state_updates": {},
        "intent": "show_places",
        "place_query": {"categories": ["museum"], "limit": 5},
    })
    picked, museum, body = _add_museum_chat(client, monkeypatch, reply)

    planning = body["planning"]
    assert planning["state_updates"]["destination_ids"] == [
        picked["destination_id"], museum["destination_id"],
    ]
    assert planning["recommendations"] == []


def test_a_guessed_return_trip_is_dropped_and_the_next_question_follows(
    client, monkeypatch,
) -> None:
    """Live case: "Just a day trip" made the model guess a return trip, and the
    traveler saw "I could not use the return trip". Now the note says what was not
    assumed and the plan's next question follows."""
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    park = create_destination(
        client, headers=admin_headers(client), name="Green Park", category="park",
        vibes="nature, relaxing", activities="walking", **verified_arrival(0),
    )
    reply = json.dumps({
        "chat_response": "Got it, a day trip with a return.",
        "state_updates": {"day_count": 1, "night_count": 0, "return_to_origin": True},
        "intent": "plan_trip",
    })
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([reply])

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Just a day trip",
            "use_rag": False,
            "planning_state": {
                "origin": {"label": "New Visayas, Panabo"},
                "traveler_count": 1,
                "destination_ids": [park["destination_id"]],
            },
        },
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert "could not use" not in body["chat_response"]
    assert "haven't assumed whether you'll return to New Visayas, Panabo" in body["chat_response"]
    # The day trip itself (explicit words) was kept.
    assert body["planning"]["state_updates"]["day_count"] == 1
    assert "return_to_origin" not in body["planning"]["state_updates"]
    assert body["chat_response"].endswith("What budget do you have in mind?")


def test_no_model_quick_replies_while_the_app_asks_with_its_own_buttons(
    client, monkeypatch,
) -> None:
    """Live case: "Tomorrow", "Next weekend" chips from the model failed when tapped,
    next to the app's own date buttons."""
    configure_ai(monkeypatch)
    reply = json.dumps({
        "chat_response": "When are you planning to travel?",
        "state_updates": {},
        "intent": "plan_trip",
        "suggested_replies": ["Tomorrow", "Next weekend", "This coming Friday"],
    })
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([reply])

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Easy",
            "use_rag": False,
            "planning_state": {
                "origin": {"label": "Davao City"},
                "traveler_count": 1, "day_count": 1, "night_count": 0,
                "total_budget": "600", "interests": ["nature_attractions"],
                "activity_level": "easy",
            },
        },
    )

    assert response.status_code == 200, response.text
    planning = response.json()["planning"]
    assert planning["conversation"]["missing_details"][0] == "travel_start_date"
    assert planning["suggested_replies"] == []


def test_quick_replies_stay_when_the_next_question_is_a_free_one(
    client, monkeypatch,
) -> None:
    configure_ai(monkeypatch)
    reply = json.dumps({
        "chat_response": "How many days do you have?",
        "state_updates": {},
        "intent": "plan_trip",
        "suggested_replies": ["Just a day trip", "2 days, 1 night"],
    })
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([reply])

    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": "Just me",
            "use_rag": False,
            "planning_state": {
                "origin": {"label": "Davao City"},
                "traveler_count": 1, "interests": ["nature_attractions"],
            },
        },
    )

    assert response.status_code == 200, response.text
    assert response.json()["planning"]["suggested_replies"] == [
        "Just a day trip", "2 days, 1 night",
    ]

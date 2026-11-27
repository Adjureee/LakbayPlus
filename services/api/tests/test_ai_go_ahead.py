"""A clear "plan it" starts the trip instead of repeating the offer to plan.

Live case (26 Nov): with places picked and every detail given, "Let's plan this trip"
got intent "question" and the same "add more places or start planning?" reply, so the
app never built the itinerary. The server now sets intent "plan_trip" itself.
"""

import json

import pytest

from app.features.ai import router as ai_router_module
from app.features.ai.schemas import AIChatMessage, AIChatRequest
from app.features.ai.service import PLAN_NOW_REPLY, _is_go_ahead
from app.integrations.groq.client import get_groq_client
from tests.test_phase5_ai_itineraries import (
    FakeGroqClient,
    admin_headers,
    configure_ai,
    create_destination,
    user_headers,
)
from tests.test_planning_chat import CandidateOSRM, planning_state, verified_arrival

OFFER = "You have 1 stop picked. Would you like to add more places or start planning?"


def _request(message: str, last_assistant: str | None = OFFER) -> AIChatRequest:
    history = [AIChatMessage(role="assistant", content=last_assistant)] if last_assistant else []
    return AIChatRequest(message=message, history=history)


@pytest.mark.parametrize(
    "message",
    [
        "Let's plan this trip",
        "lets plan it",
        "Start planning my trip",
        "Start planning the trip",
        "please plan my trip",
        "go ahead and plan",
        "Generate my itinerary",
        "yes",
        "Yes please!",
        "ok",
    ],
)
def test_a_clear_go_ahead_is_recognised(message) -> None:
    assert _is_go_ahead(_request(message))


@pytest.mark.parametrize(
    "message",
    [
        "Add more places",
        "add the National Museum and plan it",
        "Show me other museums",
        "How do I plan my trip?",
        "What should I plan for?",
        "Plan a trip for 2 people",
        "no",
        "Just me",
    ],
)
def test_other_messages_are_not_a_go_ahead(message) -> None:
    assert not _is_go_ahead(_request(message))


def test_a_bare_yes_needs_an_offer_to_plan_just_before() -> None:
    assert not _is_go_ahead(_request("yes", last_assistant=None))
    assert not _is_go_ahead(_request("yes", last_assistant="Which beaches do you like?"))


def _ask(client, message, model_reply, state, history=()):
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([model_reply])
    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={
            "message": message, "use_rag": True, "planning_state": state,
            "history": list(history),
        },
    )
    assert response.status_code == 200, response.text
    return response.json()


def _offer_reply() -> str:
    return json.dumps({
        "chat_response": OFFER,
        "state_updates": {},
        "intent": "question",
        "suggested_replies": ["Add more places", "Start planning my trip"],
    })


def test_a_go_ahead_with_every_detail_starts_the_trip(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    place = create_destination(
        client, headers=admin_headers(client), name="Alder Cove Beach Resort",
        category="beach", **verified_arrival(0),
    )

    body = _ask(
        client, "Let's plan this trip", _offer_reply(), planning_state(place["destination_id"]),
        history=[{"role": "assistant", "content": OFFER}],
    )

    assert body["planning"]["intent"] == "plan_trip"
    assert body["chat_response"] == PLAN_NOW_REPLY
    assert body["planning"]["recommendations"] == []
    assert body["planning"]["suggested_replies"] == []


def test_a_go_ahead_with_a_detail_missing_keeps_asking_for_it(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    place = create_destination(
        client, headers=admin_headers(client), name="Alder Cove Beach Resort",
        category="beach", **verified_arrival(0),
    )
    state = planning_state(place["destination_id"])
    state.pop("total_budget")

    body = _ask(client, "Let's plan this trip", _offer_reply(), state)

    assert body["planning"]["intent"] == "question"
    assert body["chat_response"] != PLAN_NOW_REPLY


def test_adding_more_places_is_not_turned_into_a_trip(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    place = create_destination(
        client, headers=admin_headers(client), name="Alder Cove Beach Resort",
        category="beach", **verified_arrival(0),
    )

    body = _ask(client, "Add more places", _offer_reply(), planning_state(place["destination_id"]))

    assert body["planning"]["intent"] != "plan_trip"

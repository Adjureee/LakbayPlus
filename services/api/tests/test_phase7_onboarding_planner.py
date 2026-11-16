"""Phase 7 tests: guest itinerary generation and Layla-style onboarding prompt rules."""

import json

from app.core.config import get_settings
from app.features.ai.schemas import AIChatRequest
from app.integrations.groq.client import get_groq_client
from app.integrations.groq.prompts import (
    CHAT_PROMPT_VERSION,
    ONBOARDING_CHAT_PROMPT_VERSION,
    build_chat_messages,
)
from tests.test_phase5_ai_itineraries import (
    FakeGroqClient,
    configure_ai,
    create_destination,
    itinerary_request,
    valid_ai_response,
)


def _chat_reply(text: str = "Here is a Samal pick!") -> str:
    return json.dumps({
        "chat_response": text,
        "state_updates": {"origin": {"label": "Panabo City"}},
        "intent": "show_places",
        "place_query": {"categories": ["beach"], "limit": 5},
        "suggested_replies": ["Show waterfalls", "2 days for 2 on 5,000"],
    })


def test_guest_itinerary_generation_works_without_sign_in(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    monkeypatch.setenv("AI_ITINERARY_OPTION_COUNT", "2")
    get_settings.cache_clear()
    destination = create_destination(client)
    dest_id = destination["destination_id"]
    fake = FakeGroqClient(
        [valid_ai_response(destination_id=dest_id, option_count=2, day_count=2)]
    )
    client.app.dependency_overrides[get_groq_client] = lambda: fake

    response = client.post(
        "/api/v1/ai/itineraries/generate/guest",
        json=itinerary_request(
            dest_id,
            model_role="quality",
            allow_fallback=False,
            compare_models=True,
            planning_state={
                "origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128},
                "destination_ids": [dest_id],
                "traveler_count": 2,
                "day_count": 2,
                "total_budget": "10000.00",
                "budget_scope": "whole_trip",
                "interests": ["beach"],
            },
            input_revision=1,
        ),
    )

    assert response.status_code == 200, response.text
    body = response.json()
    assert len(body["options"]) == 2
    assert fake.calls[0]["model"] == "default-model"
    assert body["model_runs"][0]["model_role"] == "default"
    assert body["model_runs"][0]["status"] == "succeeded"


def test_guest_itinerary_generation_respects_rate_limit_and_disable_flag(
    client, monkeypatch
) -> None:
    configure_ai(monkeypatch)
    monkeypatch.setenv("AI_ITINERARY_OPTION_COUNT", "2")
    monkeypatch.setenv("GUEST_AI_REQUESTS_PER_MINUTE", "1")
    get_settings.cache_clear()
    destination = create_destination(client)
    dest_id = destination["destination_id"]
    fake = FakeGroqClient([
        valid_ai_response(destination_id=dest_id, option_count=2, day_count=2),
        valid_ai_response(destination_id=dest_id, option_count=2, day_count=2),
    ])
    client.app.dependency_overrides[get_groq_client] = lambda: fake

    first = client.post(
        "/api/v1/ai/itineraries/generate/guest",
        headers={"X-Forwarded-For": "203.0.113.42"},
        json=itinerary_request(dest_id),
    )
    assert first.status_code == 200

    limited = client.post(
        "/api/v1/ai/itineraries/generate/guest",
        headers={"X-Forwarded-For": "203.0.113.42"},
        json=itinerary_request(dest_id),
    )
    assert limited.status_code == 429
    assert limited.json()["error"]["code"] == "ai_guest_rate_limit_exceeded"

    monkeypatch.setenv("GUEST_AI_CHAT_ENABLED", "false")
    get_settings.cache_clear()
    disabled = client.post(
        "/api/v1/ai/itineraries/generate/guest",
        json=itinerary_request(dest_id),
    )
    assert disabled.status_code == 403
    assert disabled.json()["error"]["code"] == "guest_ai_chat_disabled"


def test_onboarding_prompt_version_and_rules_applied_to_guest_chat(
    client, monkeypatch
) -> None:
    configure_ai(monkeypatch)
    fake = FakeGroqClient([_chat_reply(), _chat_reply("Regular reply")])
    client.app.dependency_overrides[get_groq_client] = lambda: fake

    onb_resp = client.post(
        "/api/v1/ai/chat/guest",
        json={
            "message": "Inspire me! Leaving from Panabo.",
            "is_onboarding": True,
            "use_rag": False,
            "planning_state": {
                "origin": {"label": "Panabo City", "lat": 7.3081, "lng": 125.6842},
                "destination_ids": [],
            },
        },
    )
    assert onb_resp.status_code == 200, onb_resp.text
    onb_system_prompt = fake.calls[0]["messages"][0]["content"]
    assert "first onboarding trip planner" in onb_system_prompt
    assert "under about 110 words" in onb_system_prompt

    regular_resp = client.post(
        "/api/v1/ai/chat/guest",
        json={
            "message": "How do I get to Samal?",
            "is_onboarding": False,
            "use_rag": False,
            "planning_state": {"origin": {"label": "Panabo City"}},
        },
    )
    assert regular_resp.status_code == 200, regular_resp.text
    regular_system_prompt = fake.calls[1]["messages"][0]["content"]
    assert "first onboarding trip planner" not in regular_system_prompt
    assert ONBOARDING_CHAT_PROMPT_VERSION == "onboarding_v1"
    assert CHAT_PROMPT_VERSION != ONBOARDING_CHAT_PROMPT_VERSION

    built = build_chat_messages(
        request=AIChatRequest(
            message="3-day Samal beach weekend for 2 on 8000 PHP",
            is_onboarding=True,
            planning_state={"origin": {"label": "Davao City"}},
        )
    )
    assert "state_updates immediately" in built[0]["content"]


def test_show_places_broad_browse_does_not_filter_to_origin_city_and_parser_handles_wrapped_json(
    client, monkeypatch
) -> None:
    configure_ai(monkeypatch)
    samal = create_destination(
        client,
        name="Samal Coral Beach",
        district="Davao del Norte",
        location="Samal Island",
        category="beach",
        lat=7.087,
        lng=125.667,
    )
    # Simulates a fallback model wrapping JSON in prose and omitting state_updates.
    wrapped_reply = (
        'Here you go:\n'
        '{"chat_response": "Try Samal Coral Beach across the gulf!", '
        '"intent": "show_places", '
        '"place_query": {"categories": ["beach"], "limit": 5}, '
        '"suggested_replies": ["How do I take the ferry?"]}'
    )
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([wrapped_reply])

    resp = client.post(
        "/api/v1/ai/chat/guest",
        json={
            "message": "Show me nice beaches",
            "is_onboarding": True,
            "use_rag": False,
            "planning_state": {"origin": {"label": "Davao City", "lat": 7.0731, "lng": 125.6128}},
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert "Samal Coral Beach" in body["chat_response"]
    recs = body["planning"]["recommendations"]
    assert [item["destination_id"] for item in recs] == [samal["destination_id"]]

"""Signed-out chat goes through the backend so the app never ships an AI key."""

import json

from app.core.config import get_settings
from app.integrations.groq.client import get_groq_client
from tests.test_phase5_ai_itineraries import FakeGroqClient, configure_ai


def _reply(text: str = "Try Samal: take the RoRo barge from Sasa Wharf.") -> str:
    return json.dumps({
        "chat_response": text,
        "state_updates": {},
        "intent": "logistics",
        "suggested_replies": ["Barge schedule?"],
    })


def _post(client, headers=None, **body):
    return client.post("/api/v1/ai/chat/guest", headers=headers or {}, json={
        "message": "How do I get to Samal?",
        "use_rag": False,
        "planning_state": {"origin": {"label": "Davao City"}},
        **body,
    })


def test_guest_chat_works_without_sign_in(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    fake = FakeGroqClient([_reply()])
    client.app.dependency_overrides[get_groq_client] = lambda: fake

    response = _post(client, model_role="quality", allow_fallback=False)

    assert response.status_code == 200, response.text
    body = response.json()
    assert body["chat_response"].startswith("Try Samal")
    assert body["planning"]["intent"] == "logistics"
    # Guests cannot choose a costlier model role.
    assert fake.calls[0]["model"] == "default-model"


def test_signed_in_chat_still_requires_a_token(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    response = client.post("/api/v1/ai/chat", json={"message": "Hi"})
    assert response.status_code == 401


def test_guest_chat_is_limited_per_client(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    monkeypatch.setenv("GUEST_AI_REQUESTS_PER_MINUTE", "2")
    get_settings.cache_clear()
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient(
        [_reply(), _reply(), _reply(), _reply()],
    )
    phone_a = {"X-Forwarded-For": "203.0.113.5, 10.0.0.1"}
    phone_b = {"X-Forwarded-For": "198.51.100.7"}

    assert _post(client, phone_a).status_code == 200
    assert _post(client, phone_a).status_code == 200
    limited = _post(client, phone_a)
    assert limited.status_code == 429
    assert limited.json()["error"]["code"] == "ai_guest_rate_limit_exceeded"
    # Another client keeps its own allowance.
    assert _post(client, phone_b).status_code == 200


def test_guest_daily_cap_is_shared(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    monkeypatch.setenv("GUEST_AI_GLOBAL_REQUESTS_PER_DAY", "1")
    get_settings.cache_clear()
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient(
        [_reply(), _reply()],
    )

    assert _post(client, {"X-Forwarded-For": "203.0.113.5"}).status_code == 200
    capped = _post(client, {"X-Forwarded-For": "198.51.100.7"})
    assert capped.status_code == 429
    assert capped.json()["error"]["code"] == "ai_guest_capacity_reached"


def test_guest_chat_can_be_disabled(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    monkeypatch.setenv("GUEST_AI_CHAT_ENABLED", "false")
    get_settings.cache_clear()

    response = _post(client)

    assert response.status_code == 403
    assert response.json()["error"]["code"] == "guest_ai_chat_disabled"


def _draft(**overrides) -> str:
    return json.dumps({
        "reply": "A breezy 2-day Samal escape: barge from Sasa, then beaches.",
        "should_create_itinerary": True,
        "title": "Samal Escape",
        "destination": "Samal Island",
        "days_count": 2,
        "suggested_replies": ["Make it 3 days"],
        "days": [{
            "day": 1, "title": "Beach day", "summary": "Sun and sand.",
            "activities": [
                {"time": "09:00 AM", "title": "Babak beach", "lat": 7.07, "lng": 125.71},
                {"time": "01:00 PM", "title": "Somewhere wrong", "lat": 14.6, "lng": 121.0},
                {"time": "03:00 PM", "title": "No coords", "lat": "x", "lng": None},
            ],
        }],
        **overrides,
    })


def test_trip_draft_for_guests_clears_off_region_coordinates(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    fake = FakeGroqClient([_draft()])
    client.app.dependency_overrides[get_groq_client] = lambda: fake

    response = client.post("/api/v1/ai/trip-draft", json={
        "message": "2 days in Samal", "preferred_vibes": ["beach"],
        "user_lat": 7.07, "user_lng": 125.61,
    })

    assert response.status_code == 200, response.text
    activities = response.json()["draft"]["days"][0]["activities"]
    assert (activities[0]["lat"], activities[0]["lng"]) == (7.07, 125.71)
    assert (activities[1]["lat"], activities[1]["lng"]) == (None, None)  # Manila
    assert (activities[2]["lat"], activities[2]["lng"]) == (None, None)
    assert response.json()["model_id"] == "default-model"


def test_trip_draft_signed_in_uses_user_limits(client, monkeypatch) -> None:
    from tests.test_phase5_ai_itineraries import user_headers

    configure_ai(monkeypatch)
    monkeypatch.setenv("GUEST_AI_CHAT_ENABLED", "false")
    get_settings.cache_clear()
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([_draft()])

    assert client.post("/api/v1/ai/trip-draft", json={"message": "Hi"}).status_code == 403
    response = client.post(
        "/api/v1/ai/trip-draft", headers=user_headers(client), json={"message": "2 days in Samal"},
    )
    assert response.status_code == 200, response.text


def test_trip_draft_rejects_unusable_model_output(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient(
        ["not json", json.dumps({"reply": ""})],
    )

    response = client.post("/api/v1/ai/trip-draft", json={"message": "Plan a trip"})

    assert response.status_code == 502
    assert response.json()["error"]["code"] == "ai_trip_draft_failed"

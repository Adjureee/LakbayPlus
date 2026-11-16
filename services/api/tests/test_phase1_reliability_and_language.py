import asyncio
import json
from types import SimpleNamespace

import httpx
import pytest

from app.core.config import Settings, get_settings
from app.features.ai.schemas import AIChatRequest, AIItineraryGenerateRequest, AITripDraftRequest
from app.features.ai.validators import AIItineraryCatalog, parse_and_validate_itinerary_output
from app.integrations.groq.client import GroqClient, _groq_model_limiter, get_groq_client
from app.integrations.groq.errors import GroqRateLimitError
from app.integrations.groq.prompts import (
    JSON_RETRY_NUDGE,
    PLANNING_PROMPT_VERSION,
    build_chat_messages,
    build_itinerary_messages,
    build_trip_draft_messages,
)
from scripts.ai_run_report import classify_failure_cause, format_report, summarize_runs
from tests.test_phase5_ai_itineraries import (
    FakeGroqClient,
    configure_ai,
    create_destination,
    itinerary_request,
    user_headers,
    valid_ai_response,
)


def _mock_transport(monkeypatch, handler):
    transport = httpx.MockTransport(handler)
    real_client = httpx.AsyncClient
    monkeypatch.setattr(
        "app.integrations.groq.client.httpx.AsyncClient",
        lambda **kwargs: real_client(transport=transport, **kwargs),
    )


def test_phase1_defaults_use_two_options_and_higher_itinerary_caps():
    settings = Settings(_env_file=None)
    assert settings.ai_itinerary_option_count == 2
    assert settings.groq_itinerary_max_tokens == 6000
    assert settings.groq_itinerary_rate_limit_max_wait_seconds == 10
    assert PLANNING_PROMPT_VERSION == "phase15e_picks_compact_v7"


def test_itinerary_prompt_compact_v7_and_language_rules():
    req = AIItineraryGenerateRequest(
        total_budget="8000.00",
        traveler_count=2,
        day_count=2,
        destination_ids=[1],
        language="bisaya",
    )
    messages = build_itinerary_messages(request=req, catalog={}, option_count=2)
    user_payload = json.loads(messages[1]["content"])
    rules_text = " ".join(user_payload["rules"])

    assert "Return exactly 2 options as ONE JSON object" in rules_text
    assert "at most 140 characters" in rules_text
    assert "Bisaya/Cebuano" in rules_text
    assert user_payload["language"] == "bisaya"


def test_chat_and_trip_draft_prompts_carry_explicit_language():
    chat_msgs = build_chat_messages(
        request=AIChatRequest(message="Unsa nindot suroyan?", language="filipino"),
    )
    assert "Filipino" in chat_msgs[0]["content"]
    assert json.loads(chat_msgs[-1]["content"])["language"] == "filipino"

    draft_msgs = build_trip_draft_messages(
        request=AITripDraftRequest(message="Beach weekend", language="english"),
        catalog_names=["Dahican Beach"],
    )
    assert '"english" (English)' in draft_msgs[0]["content"]
    assert json.loads(draft_msgs[-1]["content"])["language"] == "english"


def test_language_rejects_unsupported_values(client, monkeypatch):
    configure_ai(monkeypatch)
    headers = user_headers(client)
    res = client.post(
        "/api/v1/ai/chat",
        headers=headers,
        json={"message": "Hola", "language": "spanish"},
    )
    assert res.status_code == 422


def test_itinerary_rate_limit_waits_up_to_ten_seconds_and_retries(monkeypatch):
    _groq_model_limiter.clear()
    responses = [
        httpx.Response(429, headers={"retry-after": "8"}),
        httpx.Response(200, json={"choices": [{"message": {"content": "OK"}}]}),
    ]
    _mock_transport(monkeypatch, lambda request: responses.pop(0))
    slept: list[int] = []

    async def fake_sleep(seconds):
        slept.append(seconds)

    monkeypatch.setattr("app.integrations.groq.client.asyncio.sleep", fake_sleep)
    settings = Settings(_env_file=None, groq_api_key="key", groq_max_retries=1)
    client = GroqClient(settings)

    result = asyncio.run(
        client.create_chat_completion(
            model="quality-model",
            messages=[],
            max_tokens=settings.groq_itinerary_max_tokens,
            max_rate_limit_wait_seconds=settings.groq_itinerary_rate_limit_max_wait_seconds,
        )
    )
    assert result.content == "OK"
    assert slept == [8]
    _groq_model_limiter.clear()


def test_truncated_and_fenced_json_is_repaired_before_failing():
    valid = json.loads(valid_ai_response(destination_id=5, option_count=2))
    # Simulate markdown fence without closing fence and missing trailing closing braces.
    truncated = "```json\n" + json.dumps(valid)[:-3]
    catalog = AIItineraryCatalog(
        destination_ids={5},
        accommodation_ids=set(),
        transportation_ids=set(),
        total_budget=valid["options"][0]["estimated_total_cost"] and __import__("decimal").Decimal("5000.00"),
        day_count=2,
        minimum_option_count=2,
        required_destination_ids={5},
    )
    parsed = parse_and_validate_itinerary_output(content=truncated, catalog=catalog)
    assert len(parsed) == 2

    # Also test truncation inside an unclosed string value in notes on the last activity.
    valid["options"][1]["days"][-1]["activities"][-1]["notes"] = "Bring extra cash"
    raw = json.dumps(valid)
    cut_in_notes = raw[: raw.rfind("Bring extra") + 7]
    repaired = parse_and_validate_itinerary_output(content=cut_in_notes, catalog=catalog)
    assert len(repaired) == 2
    assert repaired[1].days[-1].activities[-1].notes == "Bring e"


def test_itinerary_retries_once_on_same_model_after_invalid_json_and_succeeds(client, monkeypatch):
    configure_ai(monkeypatch)
    monkeypatch.setenv("AI_ITINERARY_OPTION_COUNT", "2")
    get_settings.cache_clear()
    destination = create_destination(client)
    valid_two = valid_ai_response(destination_id=destination["destination_id"], option_count=2)
    fake = FakeGroqClient(["Sorry, I am not outputting JSON", valid_two])
    client.app.dependency_overrides[get_groq_client] = lambda: fake

    response = client.post(
        "/api/v1/ai/itineraries/generate",
        headers=user_headers(client),
        json=itinerary_request(destination["destination_id"], language="filipino"),
    )

    assert response.status_code == 200
    body = response.json()
    assert len(body["options"]) == 2
    assert len(fake.calls) == 2
    assert fake.calls[0]["model"] == "quality-model"
    assert fake.calls[1]["model"] == "quality-model"
    assert fake.calls[0]["max_tokens"] == 6000
    assert fake.calls[0]["max_rate_limit_wait_seconds"] == 10
    assert fake.calls[1]["messages"][-1]["content"] == JSON_RETRY_NUDGE
    assert "filipino" in fake.calls[0]["messages"][1]["content"]


def test_rate_limit_then_invalid_json_then_valid_fallback(client, monkeypatch):
    configure_ai(monkeypatch)
    monkeypatch.setenv("AI_ITINERARY_OPTION_COUNT", "2")
    monkeypatch.setenv("FALLBACK_LLM_API_KEY", "key")
    monkeypatch.setenv("FALLBACK_LLM_MODEL", "gemini-flash")
    get_settings.cache_clear()
    destination = create_destination(client)
    valid_two = valid_ai_response(destination_id=destination["destination_id"], option_count=2)

    class CascadeClient:
        def __init__(self) -> None:
            self.calls: list[tuple[str, str]] = []
            self.fallback_attempt = 0

        async def create_chat_completion(
            self,
            *,
            model,
            messages,
            response_format=None,
            provider="groq",
            temperature=None,
            max_tokens=None,
            max_rate_limit_wait_seconds=None,
        ):
            self.calls.append((model, provider))
            if provider == "groq":
                raise GroqRateLimitError("Groq rate limit reached.", retry_after_seconds=25)
            self.fallback_attempt += 1
            content = "not json at all" if self.fallback_attempt == 1 else valid_two
            from app.integrations.groq.schemas import GroqChatCompletion

            return GroqChatCompletion(
                content=content,
                model=model,
                prompt_tokens=10,
                completion_tokens=20,
                total_tokens=30,
            )

    cascade = CascadeClient()
    client.app.dependency_overrides[get_groq_client] = lambda: cascade

    response = client.post(
        "/api/v1/ai/itineraries/generate",
        headers=user_headers(client),
        json=itinerary_request(destination["destination_id"]),
    )

    assert response.status_code == 200
    assert cascade.calls == [
        ("quality-model", "groq"),
        ("gemini-flash", "fallback_llm"),
        ("gemini-flash", "fallback_llm"),
    ]


def test_ai_run_report_summarizes_causes():
    runs = [
        SimpleNamespace(
            status="succeeded",
            request_purpose="itinerary_generation",
            model_id="gpt-oss-120b",
            validation_status="valid",
            error_message=None,
            output_summary={"json_retry_used": True},
            total_tokens=1800,
            response_time_ms=950,
        ),
        SimpleNamespace(
            status="failed",
            request_purpose="itinerary_generation",
            model_id="gpt-oss-120b",
            validation_status="not_run",
            error_message="Groq rate limit reached. Please try again shortly.",
            output_summary=None,
            total_tokens=None,
            response_time_ms=120,
        ),
        SimpleNamespace(
            status="failed",
            request_purpose="itinerary_generation",
            model_id="gemini-flash",
            validation_status="invalid",
            error_message="AI output was not valid JSON.",
            output_summary={"failure_cause": "invalid_json"},
            total_tokens=None,
            response_time_ms=400,
        ),
    ]
    summary = summarize_runs(runs)
    assert summary["total_runs"] == 3
    assert summary["failure_causes"] == {"rate_limit": 1, "invalid_json": 1}
    assert summary["by_model"]["gpt-oss-120b"]["json_retry_used"] == 1
    assert classify_failure_cause(error_message="Model rejected the request.") == "model_unavailable"
    report = format_report(summary)
    assert "rate_limit: 1" in report
    assert "invalid_json: 1" in report

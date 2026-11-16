"""Opt-in live evaluation of Lakbay AI chat quality on Davao questions.

Runs every case in tests/fixtures/chat_eval_davao.json through the real
/api/v1/ai/chat planning path (RAG over a seeded test catalog, the model in your
local .env) and scores each reply on simple, explainable checks:

- valid:   the model returned usable planning JSON (not "invalid_output")
- intent:  the model's intent is one of the expected ones
- content: at least one expected keyword appears; no forbidden phrase appears
- interest: when the case names one, the model recorded that preference key
- style:   within the word limit, no canned opener, no day-by-day schedule

It prints each reply and a summary score. Run it before and after a prompt
change and compare the totals.

Run with: python -m pytest -q -s tests/manual_chat_eval.py
Optional: LAKBAY_EVAL_LIMIT=10 to run only the first N cases.
"""

import json
import os
import re
from pathlib import Path

import pytest

from app.core.config import get_settings
from app.features.destinations.schemas import DestinationCreate
from app.seeds.davao_destinations import (
    COVERAGE_COMPLETION_DESTINATIONS,
    CURATED_VISITOR_DESTINATIONS,
    DISCOVERY_VISITOR_DESTINATIONS,
    SEED_DESTINATIONS,
)
import app.features.ai.router as ai_router_module
from tests.test_phase5_ai_itineraries import create_destination, user_headers
from tests.test_planning_chat import CandidateOSRM

CASES = json.loads(
    (Path(__file__).parent / "fixtures" / "chat_eval_davao.json").read_text(encoding="utf-8")
)["cases"]
LIMIT = int(os.environ.get("LAKBAY_EVAL_LIMIT", "0") or 0)
CANNED_OPENERS = ("great question", "certainly!", "as an ai", "i'd be happy to")
DAY_BY_DAY = re.compile(r"\bday\s*1\s*[:\-–]", re.IGNORECASE)


def score_reply(case: dict, body: dict) -> dict[str, bool]:
    reply = body.get("chat_response", "")
    text = reply.casefold()
    planning = body.get("planning") or {}
    words = len(reply.split())
    return {
        "valid": planning.get("update_status") != "invalid_output",
        "intent": planning.get("intent") in case.get("intent", []),
        "content": any(k.casefold() in text for k in case.get("any_of", []))
        and not any(k.casefold() in text for k in case.get("none_of", [])),
        "interest": (
            case["expect_interest"] in [
                i.casefold() for i in (planning.get("state_updates") or {}).get("interests", [])
            ]
            if "expect_interest" in case else True
        ),
        "style": words <= case.get("max_words", 220)
        and reply.count("?") <= case.get("max_questions", 3)
        and not text.lstrip().startswith(CANNED_OPENERS)
        and not DAY_BY_DAY.search(reply),
    }


def test_chat_eval_davao(client, monkeypatch):
    settings = get_settings()
    if not settings.groq_api_key and not settings.fallback_llm_api_key:
        pytest.skip("No GROQ_API_KEY or FALLBACK_LLM_API_KEY in the local .env")
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())

    admin = client.post("/api/v1/auth/register/admin", json={
        "full_name": "Eval Admin", "email": "eval-admin@example.com",
        "password": "password123", "confirm_password": "password123",
        "admin_registration_code": "admin-test-code",
    })
    assert admin.status_code == 201, admin.json()
    admin_auth = {"Authorization": f"Bearer {admin.json()['tokens']['access_token']}"}
    catalog = (
        SEED_DESTINATIONS + CURATED_VISITOR_DESTINATIONS
        + DISCOVERY_VISITOR_DESTINATIONS + COVERAGE_COMPLETION_DESTINATIONS
    )
    for seed in catalog:
        place = DestinationCreate.model_validate(seed).model_dump(mode="json")
        create_destination(client, headers=admin_auth, **place)
    traveler = user_headers(client)

    cases = CASES[:LIMIT] if LIMIT else CASES
    totals = {"valid": 0, "intent": 0, "content": 0, "interest": 0, "style": 0}
    for case in cases:
        response = client.post("/api/v1/ai/chat", headers=traveler, json={
            "message": case["message"],
            "use_rag": True,
            "input_revision": 1,
            "planning_state": {
                "origin": {"label": "Davao City"},
                "destination_ids": [],
                "interests": [],
                **case.get("planning_state", {}),
            },
        })
        if response.status_code != 200:
            print(f"\n[{case['id']}] HTTP {response.status_code}: {response.text[:160]}")
            continue
        body = response.json()
        checks = score_reply(case, body)
        for key, passed in checks.items():
            totals[key] += passed
        marks = " ".join(f"{key}={'ok' if passed else 'X'}" for key, passed in checks.items())
        reply = body["chat_response"].replace("\n", " ")
        print(f"\n[{case['id']}] {marks} intent={(body.get('planning') or {}).get('intent')}")
        print(f"  Q: {case['message']}")
        print(f"  A: {reply[:400].encode('ascii', 'replace').decode()}")

    count = len(cases)
    overall = sum(totals.values()) / (len(totals) * count) * 100 if count else 0
    print("\n=== Lakbay chat eval ===")
    for key, value in totals.items():
        print(f"  {key:8s} {value}/{count}")
    print(f"  overall  {overall:.0f}%")

"""Structured activities: reading, validation, the admin API and what the AI is told."""

from datetime import time
from decimal import Decimal
from types import SimpleNamespace as N

import pytest
from pydantic import ValidationError

from app.features.ai.rag import _destination_document
from app.features.destinations.activities import UNCONFIRMED, activity_summary
from app.features.destinations.schemas import DestinationActivitiesUpdate
from app.features.ai.schemas import AIChatRequest
from app.integrations.groq.prompts import build_chat_messages
from tests.test_ai_rag import destination as fake_place
from tests.test_phase5_ai_itineraries import admin_headers, create_destination, user_headers


def _activity(**fields):
    base = dict(
        name="Zipline", description=None, availability=None, schedule_note=None,
        last_admission_at=None, duration_min_minutes=None, duration_max_minutes=None,
        extra_fee=None, fee_included_in_admission=None, effort_level=None,
        accessibility_note=None, min_age=None, max_age=None, restriction_note=None,
        weather_dependency=None, best_time_note=None, best_time_basis=None,
    )
    return N(**{**base, **fields})


# --- reading ---------------------------------------------------------------------------


def test_a_bare_activity_says_availability_is_not_confirmed():
    assert activity_summary(_activity()) == f"Zipline: {UNCONFIRMED}"


def test_a_full_activity_reads_in_plain_words():
    row = _activity(
        effort_level="challenging", availability="scheduled", schedule_note="9 AM to 3 PM",
        last_admission_at=time(15, 0), duration_min_minutes=30, duration_max_minutes=45,
        extra_fee=Decimal("500"), fee_included_in_admission=False, min_age=7,
        weather_dependency="dry_weather", best_time_note="morning",
        best_time_basis="cooler and clearer views",
    )
    assert activity_summary(row) == (
        "Zipline: challenging; runs on a schedule; 9 AM to 3 PM; last admission 3:00 PM; "
        "typically 30 to 45 minutes; extra fee ₱500 (not included in admission); "
        "ages 7 and up; needs dry weather; best time: morning (cooler and clearer views)"
    )


def test_unknown_fee_is_left_out_and_zero_is_no_extra_fee():
    assert "fee" not in activity_summary(_activity(extra_fee=None))
    assert "no extra fee" in activity_summary(_activity(extra_fee=Decimal("0")))
    assert "included in admission" in activity_summary(
        _activity(extra_fee=Decimal("50"), fee_included_in_admission=True),
    )


# --- validation ------------------------------------------------------------------------


def _update(*activities):
    return DestinationActivitiesUpdate.model_validate({"activities": list(activities)})


def test_activities_must_make_sense():
    _update({"name": "Zipline"})
    for bad in (
        {"name": "Z"},
        {"name": "Zipline", "availability": "whenever"},
        {"name": "Zipline", "effort_level": "insane"},
        {"name": "Zipline", "weather_dependency": "sunny"},
        {"name": "Zipline", "extra_fee": "-1"},
        {"name": "Zipline", "duration_min_minutes": 60, "duration_max_minutes": 30},
        {"name": "Zipline", "duration_min_minutes": 0},
        {"name": "Zipline", "min_age": 12, "max_age": 4},
        {"name": "Zipline", "source_url": "nope"},
    ):
        with pytest.raises(ValidationError):
            _update(bad)
    with pytest.raises(ValidationError):  # the same name twice
        _update({"name": "Zipline"}, {"name": "zipline "})


# --- the admin API ---------------------------------------------------------------------

PAYLOAD = {"activities": [
    {"name": "Zipline", "availability": "scheduled", "schedule_note": "9 AM to 3 PM",
     "duration_min_minutes": 30, "duration_max_minutes": 45, "extra_fee": "500",
     "fee_included_in_admission": False, "effort_level": "challenging", "min_age": 7,
     "verified_at": "2026-11-01T00:00:00+08:00", "source_url": "https://example.com/zip"},
    {"name": "Nature walk", "effort_level": "easy"},
]}


def test_an_admin_saves_and_anyone_reads_the_activities(client) -> None:
    admin = admin_headers(client)
    place = create_destination(client, headers=admin)
    url = f"/api/v1/destinations/{place['destination_id']}/activities"

    assert client.get(url).json()["activities"] == []

    saved = client.put(url, headers=admin, json=PAYLOAD)
    assert saved.status_code == 200, saved.text
    rows = saved.json()["activities"]
    assert [r["name"] for r in rows] == ["Zipline", "Nature walk"]  # order kept
    assert "extra fee ₱500 (not included in admission)" in rows[0]["summary"]
    assert rows[1]["summary"] == f"Nature walk: easy; {UNCONFIRMED}"
    assert rows[0]["data_quality"] in {"supported", "estimated"}
    assert rows[1]["data_quality"] == "estimated"  # never verified
    assert client.get(url).json()["activities"][0]["name"] == "Zipline"

    # A second save replaces everything.
    again = client.put(url, headers=admin, json={"activities": [PAYLOAD["activities"][1]]})
    assert [r["name"] for r in again.json()["activities"]] == ["Nature walk"]


def test_only_an_admin_can_change_activities_and_bad_input_is_refused(client) -> None:
    admin = admin_headers(client)
    place = create_destination(client, headers=admin)
    url = f"/api/v1/destinations/{place['destination_id']}/activities"

    assert client.put(url, json=PAYLOAD).status_code in {401, 403}
    assert client.put(url, headers=user_headers(client), json=PAYLOAD).status_code == 403
    assert client.put(url, headers=admin,
                      json={"activities": [{"name": "Zipline", "min_age": 9, "max_age": 3}]},
                      ).status_code == 422
    assert client.get("/api/v1/destinations/999999/activities").status_code == 404
    assert client.put("/api/v1/destinations/999999/activities", headers=admin,
                      json=PAYLOAD).status_code == 404


def test_hours_prices_and_activities_are_saved_independently(client) -> None:
    admin = admin_headers(client)
    place = create_destination(client, headers=admin)
    base = f"/api/v1/destinations/{place['destination_id']}"
    assert client.put(f"{base}/activities", headers=admin, json=PAYLOAD).status_code == 200
    assert client.put(f"{base}/hours", headers=admin,
                      json={"open_24_hours": True}).status_code == 200
    assert client.put(f"{base}/prices", headers=admin, json={"prices": []}).status_code == 200
    assert len(client.get(f"{base}/activities").json()["activities"]) == 2


# --- what the AI is told ---------------------------------------------------------------


def test_the_ai_record_carries_each_activity_with_what_is_unconfirmed():
    place = fake_place(1, "Eden Nature Park", "Davao City")
    doc = _destination_document(place, activities=[
        _activity(effort_level="challenging", availability="scheduled"), _activity(name="Walk"),
    ])
    lines = doc.payload["activity_details"]
    assert lines[0].startswith("Zipline: challenging; runs on a schedule")
    assert lines[1] == f"Walk: {UNCONFIRMED}"
    assert "Zipline" in doc.text

    assert _destination_document(place).payload.get("activity_details") is None


def test_the_prompt_tells_the_model_not_to_promise_unconfirmed_activities():
    prompt = build_chat_messages(
        request=AIChatRequest(message="What can I do at Eden?"),
    )[0]["content"]
    assert "activity_details" in prompt
    assert "availability not confirmed" in prompt
    assert "does not mean every activity is available" in prompt

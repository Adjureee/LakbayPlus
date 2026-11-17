import json

import pytest

from app.features.ai.grounding import (
    FIGURE_NOTE,
    card_figures_text,
    clock_times,
    facts_text,
    ground_figures,
)
from app.integrations.groq.client import get_groq_client
from tests.test_phase5_ai_itineraries import (
    FakeGroqClient,
    admin_headers,
    configure_ai,
    create_destination,
    user_headers,
)


def test_the_dahican_answer_loses_every_figure_the_record_does_not_hold():
    """Live case: a route time, distance, fare and surf hours the catalog never gave."""
    reply = (
        "From Mati City center, take a tricycle heading south; it is about 6 km and takes "
        "15‑20 minutes (≈₱150‑₱200 for a tricycle). "
        "Parking is available at the entrance.\n\n"
        "Tip: Visit early morning (7‑9 am) during the dry season for the best surf."
    )
    text, dropped = ground_figures(reply, "Dahican Surf Resort operating hours 24/7")
    assert dropped == 2
    assert "6 km" not in text and "₱150" not in text and "7‑9 am" not in text
    assert "Parking is available at the entrance." in text
    assert text.endswith(FIGURE_NOTE)


def test_figures_that_the_facts_hold_stay():
    support = "Ferry from Davao City Wharf 20-40 minutes price 150.00 entrance fee PHP 160 per person"
    reply = "The ferry takes 20-40 minutes for ₱150. Entry is ₱160 per person."
    text, dropped = ground_figures(reply, support)
    assert dropped == 0 and text == reply


def test_opening_hours_match_whatever_format_the_record_uses():
    reply = "It is open from 6:00 AM to 5:00 PM daily."
    assert ground_figures(reply, "Mo-Su 06:00-17:00")[1] == 0
    assert ground_figures(reply, "Mo-Su 07:00-17:00")[1] == 1


@pytest.mark.parametrize(
    ("reply", "support", "dropped"),
    [
        ("It takes 1 hour.", "duration 60 minutes", 0),
        ("It takes 90 minutes.", "duration 1.5 hours", 0),
        ("It takes 2 hours.", "duration 60", 1),
        ("Budget is ₱1,000.", "budget 1000", 0),
        ("Budget is ₱1,000.", "budget 600", 1),
        ("That is 150 pesos.", "price 150.00", 0),
        ("That is 5 km away.", "5", 0),
        ("That is 6.5 km away.", "5", 1),
    ],
)
def test_units_and_conversions(reply, support, dropped):
    assert ground_figures(reply, support)[1] == dropped


def test_counts_and_unitless_numbers_are_left_alone():
    reply = "Lakbay lists 4 museums and 2 waterfalls. You have 3 stops."
    assert ground_figures(reply, "")[0] == reply


def test_a_reply_that_is_all_unsupported_becomes_just_the_note():
    text, dropped = ground_figures("It costs ₱999.", "")
    assert dropped == 1 and text == FIGURE_NOTE


def test_the_note_is_added_once_and_paragraphs_survive():
    reply = f"First paragraph.\n\nIt costs ₱999. It takes 45 minutes.\n\n{FIGURE_NOTE}"
    text, dropped = ground_figures(reply, "")
    assert dropped == 2 and text.count(FIGURE_NOTE) == 1
    assert text.startswith("First paragraph.")


def test_clock_times_cover_ranges_and_24_hour_text():
    assert clock_times("7-9 am") == {"07:00", "09:00"}
    assert clock_times("10:00 AM - 5:00 PM") == {"10:00", "17:00"}
    assert clock_times("Mo-Su 06:00-17:00") == {"06:00", "17:00"}


def test_record_ids_never_count_as_support():
    records = [{"facts": {"destination_id": 42, "transportation_id": 7, "price": "150.00",
                          "lat": 7.3, "name": "Plaza"}}]
    text = facts_text(records)
    assert "150.00" in text and "42" not in text and "7.3" not in text
    assert ground_figures("It takes 42 minutes.", text)[1] == 1


def test_card_figures_are_support():
    class Card:
        def model_dump(self, mode="json"):
            return {"travel_minutes": 34, "estimated_cost": "300.00", "destination_id": 9,
                    "name": "Park", "matched_fields": ["category"]}

    text = card_figures_text([Card()])
    assert "34" in text and "300.00" in text and "9" not in text.split()


def _chat(client, message, model_reply, state=None, use_rag=True):
    client.app.dependency_overrides[get_groq_client] = lambda: FakeGroqClient([model_reply])
    response = client.post(
        "/api/v1/ai/chat",
        headers=user_headers(client),
        json={"message": message, "use_rag": use_rag,
              "planning_state": state or {"origin": {"label": "Davao City"}}},
    )
    assert response.status_code == 200, response.text
    return response.json()


def test_the_chat_removes_invented_figures_and_says_so(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    create_destination(client, headers=admin_headers(client), name="Dahican Surf Resort")
    reply = json.dumps({
        "chat_response": "Take a tricycle, about 6 km and 15 minutes for ₱150. "
                         "The road is paved.",
        "state_updates": {}, "intent": "logistics",
    })

    body = _chat(client, "How do I get to Dahican Surf Resort?", reply)

    assert "6 km" not in body["chat_response"]
    assert "₱150" not in body["chat_response"]
    assert "The road is paved." in body["chat_response"]
    assert FIGURE_NOTE in body["chat_response"]


def test_the_chat_keeps_figures_the_catalog_gave(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    create_destination(
        client, headers=admin_headers(client), name="Dahican Surf Resort",
        entrance_fee="PHP 160 per person", operating_hours="Mo-Su 06:00-17:00",
    )
    reply = json.dumps({
        "chat_response": "Entry is ₱160 per person and it opens 6:00 AM to 5:00 PM.",
        "state_updates": {}, "intent": "question",
    })

    body = _chat(client, "How much is Dahican Surf Resort and when is it open?", reply)

    assert body["chat_response"] == "Entry is ₱160 per person and it opens 6:00 AM to 5:00 PM."


def test_the_travelers_own_budget_is_not_flagged(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    reply = json.dumps({
        "chat_response": "Got it, your budget is ₱600.",
        "state_updates": {"total_budget": 600}, "intent": "plan_trip",
    })
    body = _chat(client, "600", reply, use_rag=False)
    assert "₱600" in body["chat_response"]

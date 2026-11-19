"""Short answers read beside the question they answer, and the new trip-state fields."""

import json
from datetime import date, time
from decimal import Decimal

import pytest
from pydantic import ValidationError

from app.features.ai import router as ai_router_module
from app.features.ai.schemas import AIPlanningStateUpdates
from app.features.ai.short_answers import describe, interpret_short_answer, parse_travel_date
from app.features.planning.schemas import PlanningState
from app.integrations.groq.client import get_groq_client
from tests.test_ai_phase1b_cards_origin import _ask
from tests.test_phase5_ai_itineraries import (
    FakeGroqClient,
    admin_headers,
    configure_ai,
    create_destination,
    user_headers,
)
from tests.test_planning_chat import CandidateOSRM

TODAY = date(2026, 11, 18)  # a Wednesday


def _state(**fields) -> PlanningState:
    return PlanningState.model_validate({"destination_ids": [1], **fields})


# --- the questions in the specification ---------------------------------------------


def test_just_me_is_one_traveler():
    assert interpret_short_answer("Just me", _state(), TODAY) == {"traveler_count": 1}


def test_a_bare_number_answers_the_budget_question():
    state = _state(traveler_count=1, day_count=1, night_count=0)
    assert interpret_short_answer("600", state, TODAY) == {"total_budget": Decimal("600")}
    assert interpret_short_answer("₱1,500", state, TODAY) == {"total_budget": Decimal("1500")}


def test_a_bare_number_is_not_a_budget_when_another_question_is_open():
    # The open question is the traveler count, so "600" is not saved as a budget.
    assert "total_budget" not in interpret_short_answer("600", _state(), TODAY)


def test_easy_answers_the_activity_question_only():
    state = _state(
        interests=["nature_attractions"], traveler_count=1, day_count=1, night_count=0,
        total_budget="600",
    )
    assert interpret_short_answer("Easy", state, TODAY) == {"activity_level": "easy"}
    # Nothing is being asked about activity here, so the same word saves nothing.
    assert "activity_level" not in interpret_short_answer("Easy", _state(), TODAY)


def test_day_trip_is_one_day_with_no_overnight():
    state = _state(interests=["nature_attractions"], traveler_count=1)
    assert interpret_short_answer("Day trip", state, TODAY) == {
        "day_count": 1, "night_count": 0,
    }
    # Changing a length already set is left to the model.
    state = _state(traveler_count=1, day_count=3, night_count=2)
    assert "day_count" not in interpret_short_answer("Make it a day trip", state, TODAY)


def test_make_it_1000_instead_updates_only_the_budget():
    state = _state(traveler_count=2, day_count=1, night_count=0, total_budget="600")
    assert interpret_short_answer("Make it 1000 instead", state, TODAY) == {
        "total_budget": Decimal("1000"),
    }


def test_unrelated_messages_save_nothing():
    state = _state(traveler_count=1)
    for text in ("What is the weather like?", "Show me beaches", "thanks!", ""):
        assert interpret_short_answer(text, state, TODAY) == {}


# --- dates ----------------------------------------------------------------------------


def test_tomorrow_comes_from_todays_date():
    assert parse_travel_date("tomorrow", TODAY) == date(2026, 11, 19)
    assert parse_travel_date("tomorrow", date(2026, 12, 31)) == date(2027, 1, 1)


def test_this_month_is_ambiguous_and_saves_nothing():
    state = _state(
        interests=["nature_attractions"], traveler_count=1, day_count=1, night_count=0,
        total_budget="600", activity_level="easy",
    )
    assert parse_travel_date("this month", TODAY) is None
    assert "travel_start_date" not in interpret_short_answer("This month", state, TODAY)


def test_dates_that_need_a_year_or_a_choice():
    assert parse_travel_date("dec 5", TODAY) == date(2026, 12, 5)
    assert parse_travel_date("nov 2", TODAY) == date(2027, 11, 2)  # already past: next year
    assert parse_travel_date("this friday", TODAY) == date(2026, 11, 20)
    assert parse_travel_date("next friday", TODAY) is None  # ask for the date
    assert parse_travel_date("feb 30", TODAY) is None  # no such day
    assert parse_travel_date("this weekend", TODAY) == date(2026, 11, 21)


def test_a_date_beside_another_question_is_not_taken_for_the_date_question():
    # Asked for the traveler count, "tomorrow" alone is not a travel date.
    assert "travel_start_date" not in interpret_short_answer("tomorrow", _state(), TODAY)
    assert interpret_short_answer("we leave tomorrow", _state(), TODAY) == {
        "travel_start_date": date(2026, 11, 19),
    }


def test_times_are_saved_only_when_stated():
    found = interpret_short_answer("we want to be back by 6 pm, leaving at 7:30 am", _state(), TODAY)
    assert found["return_deadline"] == time(18, 0)
    assert found["departure_time"] == time(7, 30)
    assert interpret_short_answer("the evening is fine", _state(), TODAY) == {}


def test_describe_names_what_was_saved():
    assert describe({"traveler_count": 1}) == "1 traveler"
    assert describe({"day_count": 1, "night_count": 0}) == "a day trip"
    assert describe({"total_budget": Decimal("600")}) == "a budget of ₱600"


# --- the new fields -------------------------------------------------------------------


def test_new_trip_state_fields_are_validated():
    state = PlanningState.model_validate({
        "destination_area": "Panabo", "nearby_areas_allowed": False,
        "return_label": "Davao City", "departure_time": "07:30:00",
        "return_deadline": "18:00:00", "pace": "relaxed",
        "special_needs": ["wheelchair access"], "budget_includes": ["transport", "food"],
    })
    assert state.pace == "relaxed" and state.departure_time == time(7, 30)
    with pytest.raises(ValidationError):
        PlanningState.model_validate({"pace": "frantic"})
    with pytest.raises(ValidationError):
        PlanningState.model_validate({"budget_includes": ["souvenirs"]})


def test_the_model_cannot_write_times_but_can_write_the_rest():
    ok = AIPlanningStateUpdates.model_validate({"pace": "balanced", "special_needs": ["vegan"]})
    assert ok.pace == "balanced"
    with pytest.raises(ValidationError):
        AIPlanningStateUpdates.model_validate({"special_needs": None})
    with pytest.raises(ValidationError):
        AIPlanningStateUpdates.model_validate({"departure_time": "07:00:00"})


# --- the chat uses them ---------------------------------------------------------------


def test_a_short_answer_is_saved_even_when_the_model_fails(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())

    body = _ask(client, "Just me", "this is not json at all {{", {
        "interests": ["nature_attractions"],
    })

    state = body["planning"]["preview"]["state"]
    assert state["traveler_count"] == 1
    assert body["planning"]["state_updates"]["traveler_count"] == 1
    assert body["planning"]["update_status"] == "applied"
    assert body["message"]  # the traveler still gets a reply
    assert "couldn't safely update" not in json.dumps(body)


def test_what_the_words_say_wins_over_a_wrong_model_guess(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    reply = json.dumps({
        "chat_response": "Got it.", "state_updates": {"traveler_count": 4},
        "intent": "plan_trip",
    })

    body = _ask(client, "Just me", reply, {"interests": ["nature_attractions"]})

    assert body["planning"]["preview"]["state"]["traveler_count"] == 1


def test_an_ambiguous_answer_changes_nothing(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    place = create_destination(client, headers=admin_headers(client))
    reply = json.dumps({
        "chat_response": "Which date exactly?", "state_updates": {}, "intent": "plan_trip",
    })
    state = {
        "destination_ids": [place["destination_id"]],
        "interests": ["nature_attractions"], "traveler_count": 1, "day_count": 1,
        "night_count": 0, "total_budget": "600", "activity_level": "easy",
    }

    body = _ask(client, "This month", reply, state)

    assert body["planning"]["preview"]["state"].get("travel_start_date") is None
    assert body["planning"]["state_updates"] == {}
    # The model's "Which date exactly?" is replaced by the server's own request, so a
    # reply that treats "this month" as settled can never reach the traveler.
    assert "exact day" in body["chat_response"]


def test_only_a_vague_answer_to_the_date_question_asks_again():
    from app.features.ai.short_answers import is_vague_date_answer

    state = _state(
        interests=["nature_attractions"], traveler_count=1, day_count=1, night_count=0,
        total_budget="600", activity_level="easy",
    )
    for text in ("This month", "next friday", "sometime next week", "soon"):
        assert is_vague_date_answer(text, state, TODAY), text
    for text in ("Tomorrow", "Dec 5", "How about this month?", "Show me beaches"):
        assert not is_vague_date_answer(text, state, TODAY), text
    # Not the date question: no effect.
    assert not is_vague_date_answer("This month", _state(), TODAY)


def test_a_budget_correction_updates_only_the_budget(client, monkeypatch) -> None:
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    reply = json.dumps({
        "chat_response": "Done.", "state_updates": {}, "intent": "modify_trip",
    })
    state = {
        "interests": ["nature_attractions"], "traveler_count": 2, "day_count": 1,
        "night_count": 0, "total_budget": "600",
    }

    body = _ask(client, "Make it 1000 instead", reply, state)

    saved = body["planning"]["preview"]["state"]
    assert Decimal(str(saved["total_budget"])) == Decimal("1000")
    assert saved["traveler_count"] == 2 and saved["day_count"] == 1


def test_browsing_a_town_records_it_as_the_destination_area(client, monkeypatch) -> None:
    from tests.test_ai_phase1b_cards_origin import _town_catalog

    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    _town_catalog(client)
    reply = json.dumps({
        "chat_response": "Yes, Panabo has a few places.", "state_updates": {},
        "intent": "question",
    })

    body = _ask(client, "is there a place to go in panabo?", reply, {
        "origin": {"label": "New Visayas, Panabo", "lat": 7.3079, "lng": 125.6841},
        "selected_transport_option_ids": ["mode:personal_vehicle"],
    })

    assert body["planning"]["preview"]["state"]["destination_area"] == "Panabo"

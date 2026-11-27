from datetime import date
from decimal import Decimal

import pytest
from pydantic import ValidationError

from app.features.ai.conversation_stage import compute_stage, missing_details
from app.features.planning.schemas import PlanningState


def test_empty_state_is_collect_and_asks_for_interests_first():
    result = compute_stage(PlanningState())
    assert result.stage == "collect"
    assert result.missing_details[0] == "interests"
    assert result.next_question == "What kind of places do you enjoy?"


def test_interests_without_picks_is_recommend():
    result = compute_stage(PlanningState(interests=["beaches"]))
    assert result.stage == "recommend"
    assert "interests" not in result.missing_details


def test_any_pick_is_picking_stage():
    result = compute_stage(PlanningState(interests=["beaches"], destination_ids=[1, 2]))
    assert result.stage == "picking"


def test_nature_adds_one_at_a_time_questions_after_core_details():
    state = PlanningState(
        interests=["nature_attractions"], traveler_count=2, day_count=2,
        total_budget=Decimal("5000"),
    )
    assert missing_details(state) == ("activity_level", "travel_start_date", "prefers_quiet")
    answered = state.model_copy(update={"activity_level": "easy", "prefers_quiet": True})
    assert missing_details(answered) == ("travel_start_date",)


def test_priorities_are_offered_only_after_the_nature_questions_are_answered():
    state = PlanningState(interests=["nature_attractions"])
    assert compute_stage(state).optional_details == ()
    answered = state.model_copy(update={
        "activity_level": "easy", "travel_start_date": date(2027, 1, 1), "prefers_quiet": False,
    })
    assert compute_stage(answered).optional_details == ("priority_order",)
    ranked = answered.model_copy(update={"priority_order": ["scenery"]})
    assert compute_stage(ranked).optional_details == ()


def test_nature_words_are_recognised_as_nature():
    state = PlanningState(interests=["waterfalls"])
    assert "activity_level" in missing_details(state)


def test_non_nature_interests_never_ask_nature_questions():
    assert "activity_level" not in missing_details(PlanningState(interests=["beaches"]))


def test_answered_details_are_not_asked_again():
    state = PlanningState(
        interests=["beaches"], traveler_count=2, day_count=3, total_budget=Decimal("8000"),
        travel_start_date=date(2027, 1, 10),
    )
    assert missing_details(state) == ()


def test_priority_order_rejects_unknown_and_repeated_priorities():
    with pytest.raises(ValidationError):
        PlanningState(priority_order=["not_a_priority"])
    with pytest.raises(ValidationError):
        PlanningState(priority_order=["quiet", "quiet"])


def test_travel_start_date_question_asks_for_a_specific_day():
    from app.features.ai.conversation_stage import QUESTIONS

    prompt = QUESTIONS["travel_start_date"]
    assert "just the month" not in prompt.lower()
    assert "day" in prompt.lower()


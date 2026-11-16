"""Where a planning conversation stands, worked out from the planning state.

The server computes the stage and the details still missing and gives both to
the model, so the model never decides for itself whether to ask a question,
show places or move on. Nothing here is guessed: a detail is "missing" only
when the state has no value for it.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Literal

from app.features.planning.schemas import PlanningState
from app.features.recommendations.preference_groups import load_groups

Stage = Literal["collect", "recommend", "picking"]

NATURE_GROUP = "nature_attractions"

# Plain-language question for each missing detail, asked one at a time.
QUESTIONS = {
    "interests": "What kind of places do you enjoy?",
    "traveler_count": "How many people are going?",
    "day_count": "How many days do you have?",
    "total_budget": "What budget do you have in mind?",
    "activity_level": "How active do you want to be: easy, moderate, or challenging?",
    "travel_start_date": "When are you travelling? A date or just the month is fine.",
    "prefers_quiet": "Do you prefer quiet places or popular ones?",
}


@dataclass(frozen=True)
class ConversationStage:
    stage: Stage
    # Ordered by what to ask first; the model asks only the first one.
    missing_details: tuple[str, ...]
    # Questions the traveler may answer but need not ("what matters most?").
    # The app offers them as buttons; the AI never asks them in prose.
    optional_details: tuple[str, ...] = ()

    @property
    def next_question(self) -> str | None:
        return QUESTIONS.get(self.missing_details[0]) if self.missing_details else None

    def as_prompt_payload(self) -> dict:
        return {
            "stage": self.stage,
            "missing_details": list(self.missing_details),
            "ask_next": self.next_question,
            "optional_details": list(self.optional_details),
        }


def wants_nature(state: PlanningState) -> bool:
    """True when any saved interest resolves to the Nature attractions group."""
    groups = load_groups()
    for interest in state.interests:
        resolved = groups.resolve(interest)
        if resolved is not None and resolved.group == NATURE_GROUP:
            return True
    return False


def missing_details(state: PlanningState) -> tuple[str, ...]:
    missing: list[str] = []
    if not state.interests and not state.destination_ids:
        missing.append("interests")
    if state.traveler_count is None:
        missing.append("traveler_count")
    if state.day_count is None:
        missing.append("day_count")
    if state.total_budget is None:
        missing.append("total_budget")
    if wants_nature(state):
        if state.activity_level is None:
            missing.append("activity_level")
        if state.travel_start_date is None:
            missing.append("travel_start_date")
        if state.prefers_quiet is None:
            missing.append("prefers_quiet")
    return tuple(missing)


def compute_stage(state: PlanningState) -> ConversationStage:
    """`collect`, `recommend` or `picking`.

    Generating and refining happen after an itinerary request, which the app
    makes explicitly, so the server never infers them from the state.
    """
    missing = missing_details(state)
    if state.destination_ids:
        stage: Stage = "picking"
    elif state.interests:
        stage = "recommend"
    else:
        stage = "collect"
    nature_done = wants_nature(state) and not any(
        name in missing for name in ("activity_level", "travel_start_date", "prefers_quiet")
    )
    optional = ("priority_order",) if nature_done and not state.priority_order else ()
    return ConversationStage(stage=stage, missing_details=missing, optional_details=optional)

import json
from datetime import date
from pathlib import Path

from app.features.ai.schemas import AIChatRequest, AIItineraryGenerateRequest, AITripDraftRequest
from app.features.planning.schemas import PlanningState
from app.integrations.groq.prompts import (
    available_interests,
    build_chat_messages,
    build_itinerary_messages,
    build_trip_draft_messages,
)


def _itinerary(**request):
    base = dict(total_budget="6000.00", traveler_count=2, day_count=2, destination_ids=[1, 2])
    messages = build_itinerary_messages(
        request=AIItineraryGenerateRequest(**base, **request), catalog={}, option_count=2,
    )
    return messages[0]["content"], json.loads(messages[1]["content"])


def test_itinerary_prompt_uses_only_the_picked_places_and_no_fixed_corridors():
    _, user = _itinerary()
    rules = " ".join(user["rules"])
    assert "never add, swap or suggest a destination the traveler did not pick" in rules
    # The hard-coded corridor list and fixed option personas are gone.
    assert "corridors" not in rules
    assert "Toril" not in rules and "Cateel" not in rules
    assert "Budget & public-transit" not in rules and "Relaxed scenic" not in rules


def test_itinerary_prompt_carries_only_what_the_traveler_said():
    _, bare = _itinerary()
    assert bare["traveler_preferences"] == {"interests": []}

    state = PlanningState(
        interests=["nature_attractions"], activity_level="easy", prefers_quiet=True,
        priority_order=["scenery", "quiet"], travel_start_date=date(2027, 2, 3),
    )
    _, user = _itinerary(planning_state=state)
    assert user["traveler_preferences"] == {
        "interests": ["nature_attractions"], "activity_level": "easy", "prefers_quiet": True,
        "priority_order": ["scenery", "quiet"], "travel_start_date": "2027-02-03",
    }


def test_trip_draft_has_no_default_location_or_fixed_example_place():
    request = AITripDraftRequest(message="2 days in Samal")
    messages = build_trip_draft_messages(request=request, catalog_names=["Hagimit Falls"])
    system = messages[0]["content"]
    payload = json.loads(messages[-1]["content"])
    for leftover in ("7.0731", "125.6128", "Sasa", "7.0742", "125.7089"):
        assert leftover not in system
    assert '"center_lat": null' in system
    assert "Use only stops named in known_lakbay_destinations" in system
    assert payload["current_location"] is None
    assert payload["known_lakbay_destinations"] == ["Hagimit Falls"]


def test_trip_draft_uses_the_travelers_own_coordinates_when_given():
    request = AITripDraftRequest(message="Hi", user_lat=7.5, user_lng=125.9)
    system = build_trip_draft_messages(request=request, catalog_names=[])[0]["content"]
    assert '"center_lat": 7.5000' in system and '"center_lng": 125.9000' in system


def test_chat_prompt_lists_the_available_interests_from_the_group_definitions():
    interests = available_interests()
    assert [i["key"] for i in interests][0] == "nature_attractions"
    assert "waterfalls" in [s["key"] for s in interests[0]["sub_types"]]

    messages = build_chat_messages(
        request=AIChatRequest(message="Hi", planning_state={}),
    )
    payload = json.loads(messages[-1]["content"])
    assert payload["available_interests"] == interests
    assert "`available_interests`" in messages[0]["content"]
    assert "nature_attractions" in messages[0]["content"]

    plain = json.loads(build_chat_messages(request=AIChatRequest(message="Hi"))[-1]["content"])
    assert "available_interests" not in plain


def test_eval_fixture_is_well_formed():
    cases = json.loads(
        (Path(__file__).parent / "fixtures" / "chat_eval_davao.json").read_text(encoding="utf-8")
    )["cases"]
    ids = [c["id"] for c in cases]
    assert len(ids) == len(set(ids)) and len(cases) >= 40
    for case in cases:
        assert case["message"].strip() and case["intent"] and case["any_of"], case["id"]
        if "planning_state" in case:
            PlanningState.model_validate(case["planning_state"])
    # Nature, stage, language and refinement coverage the plan calls for.
    assert {"nature-waterfalls-hikes", "nature-quiet-kids", "nature-no-boats",
            "mountains-digos", "stage-picking", "refine-cheaper"} <= set(ids)

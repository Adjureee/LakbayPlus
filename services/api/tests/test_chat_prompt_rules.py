from app.features.ai.schemas import AIChatRequest
from app.integrations.groq.prompts import CHAT_PROMPT_VERSION, build_chat_messages


def _system_prompt(**request) -> str:
    messages = build_chat_messages(request=AIChatRequest(message="Suggest a trip", **request))
    return messages[0]["content"]


def test_planning_chat_is_told_not_to_write_itineraries_in_chat():
    prompt = _system_prompt(planning_state={"origin": {"label": "Davao City"}})

    assert "Never write a day-by-day" in prompt
    assert "Generate itinerary" in prompt
    # The old instruction invited the model to draft itineraries in chat.
    assert "itinerary ideas" not in prompt
    assert "suggest destinations, budget tips" in prompt


def test_plain_chat_keeps_its_original_scope():
    prompt = _system_prompt()

    assert "itinerary ideas" in prompt
    assert "Never write a day-by-day" not in prompt


def test_the_prompt_version_changed_with_the_rules():
    assert CHAT_PROMPT_VERSION == "phase5_chat_v8_show_places"


def test_prompt_answers_first_in_a_local_voice():
    prompt = _system_prompt()

    assert "answer the traveler's actual question first" in prompt
    assert "Bisaya" in prompt
    assert "never by road" in prompt  # islands are reached from a pier


def test_planning_prompt_asks_for_intent_and_suggested_replies():
    prompt = _system_prompt(planning_state={"origin": {"label": "Davao City"}})

    assert "`intent`" in prompt and "plan_trip" in prompt
    assert "show_places" in prompt and "`place_query`" in prompt
    assert "`suggested_replies`" in prompt
    assert "do not turn every reply into a planning checklist" in prompt

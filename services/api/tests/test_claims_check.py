"""Claims about a place that its records do not hold (no numbers needed)."""

import json
import logging

import pytest

from app.core.config import get_settings
from app.features.ai import router as ai_router_module
from app.features.ai.claims import (
    CLAIM_NOTE,
    check_claims,
    find_unsupported_claims,
    ground_claims,
)
from app.features.ai.grounding import NO_DATA_ANSWER, _fact_values
from tests.test_ai_phase1b_cards_origin import _ask, _town_catalog
from tests.test_phase5_ai_itineraries import configure_ai
from tests.test_planning_chat import CandidateOSRM

NAMES = [(1, "Eden Nature Park"), (2, "Museo Panabo")]
EDEN = "Eden Nature Park is a green park in Toril."


def _find(reply, *, support=EDEN, message="Tell me about Eden Nature Park", names=NAMES):
    return find_unsupported_claims(
        reply, message=message, support_by_place={1: support, 2: "Museo Panabo, a museum"},
        names=names,
    )


def _rules(reply, **kw):
    return sorted(f.rule for f in _find(reply, **kw))


# --- what is flagged --------------------------------------------------------------------


@pytest.mark.parametrize("sentence, rule", [
    ("The terrain at Eden Nature Park can be uneven.", "terrain"),
    ("Eden Nature Park has ramps at the main gate.", "ramps and aids"),
    ("Visit Eden Nature Park in the dry season (Nov-May).", "season"),
    ("Eden Nature Park can fill up on weekends.", "crowds"),
    ("Most visitors park on the street near Eden Nature Park.", "parking"),
    ("Eden Nature Park has restrooms and lockers.", "facilities"),
    ("Bring cash since card terminals may be limited at Eden Nature Park.", "facilities"),
    ("Photography is not allowed inside Eden Nature Park.", "rules"),
    ("You can join guided tours at Eden Nature Park.", "guided tour"),
])
def test_a_claim_the_record_does_not_hold_is_flagged(sentence, rule):
    assert rule in _rules(sentence)


def test_the_same_words_in_the_records_make_a_claim_supported():
    support = f"{EDEN} Guided tours run daily. Restrooms near the gate. Paths can be uneven."
    for sentence in (
        "You can join guided tours at Eden Nature Park.",
        "Eden Nature Park has restrooms.",
        "The paths at Eden Nature Park can be uneven.",
    ):
        assert _rules(sentence, support=support) == []


def test_a_yes_flag_supports_its_own_words_and_nothing_more():
    # The record says wheelchair accessible: true; it does not say ramps.
    support = _fact_values({"name": "Eden Nature Park", "wheelchair_accessible": True})
    assert "wheelchair accessible" in support
    assert _rules("Eden Nature Park is wheelchair accessible.", support=support) == []
    assert _rules("Eden Nature Park has ramps and accessible paths.", support=support) == [
        "ramps and aids",
    ]


def test_typographic_hyphens_do_not_hide_a_claim():
    assert "facilities" in {f.category for f in _find(
        "Eden Nature Park is air‑conditioned.")}


# --- what is left alone -----------------------------------------------------------------


@pytest.mark.parametrize("sentence", [
    "Do you want parking details for Eden Nature Park?",
    "Parking isn't listed for Eden Nature Park.",
    "Lakbay has no record of restrooms at Eden Nature Park.",
    "Call Eden Nature Park to ask about ramps and restrooms.",
    "Tip: go early in the morning to avoid crowds at Eden Nature Park.",
    "Bring sunscreen, water and sturdy shoes.",
    "Eden Nature Park is a green park in Toril.",
])
def test_questions_honest_absence_advice_and_plain_tips_are_not_claims(sentence):
    assert _find(sentence) == []


def test_a_guess_after_an_honest_absence_is_flagged():
    """Live case: "Parking isn't listed ..., many local churches have a small lot"."""
    sentence = (
        "Parking isn't listed for Eden Nature Park, so check with the staff, but many "
        "parks have a small lot or street parking."
    )
    assert "guess after absence" in _rules(sentence)
    assert _find("Parking isn't mentioned for Eden Nature Park, so there's likely no "
                 "dedicated lot and you'll probably park nearby.")


def test_which_place_a_sentence_is_about():
    reply = "Eden Nature Park is pretty. The terrain is uneven."
    # One place in the reply: the unnamed sentence is about it.
    assert _rules(reply) == ["terrain"]
    # Two places named: an unnamed sentence is about neither, so it is left alone.
    both = "Eden Nature Park and Museo Panabo are good. The terrain is uneven."
    assert _find(both, message="Compare them") == []
    # A sentence naming two places is not checked either.
    assert _find("Eden Nature Park and Museo Panabo both have ramps.") == []
    # A sentence naming exactly one is checked against that place's own record.
    only = "Museo Panabo is small. Eden Nature Park has ramps."
    found = _find(only, message="Compare them")
    assert [(f.rule, f.destination_id) for f in found] == [("ramps and aids", 1)]
    # The record of the other place never supports it.
    other = find_unsupported_claims(
        only, message="Compare them", names=NAMES,
        support_by_place={1: EDEN, 2: "Museo Panabo has ramps"},
    )
    assert [f.rule for f in other] == ["ramps and aids"]


# --- enforcing --------------------------------------------------------------------------


def test_a_trailing_clause_is_cut_and_the_rest_kept():
    reply = "Yes, Eden Nature Park is wheelchair accessible, with ramps and accessible paths."
    findings = _find(reply, support="Eden Nature Park wheelchair accessible")
    text, changed = ground_claims(reply, findings)
    assert changed == 1
    assert text.startswith("Yes, Eden Nature Park is wheelchair accessible.")
    assert "ramps" not in text and text.endswith(CLAIM_NOTE)


def test_a_sentence_that_cannot_be_cut_is_removed_with_those_leaning_on_it():
    reply = "Eden Nature Park has ramps. It is easy to use. Bring a hat."
    text, changed = ground_claims(reply, _find(reply))
    assert "ramps" not in text and "easy to use" not in text
    assert "Bring a hat." in text and CLAIM_NOTE in text


def test_when_only_a_question_is_left_the_answer_is_the_no_data_reply():
    reply = "Eden Nature Park has ramps. What kind of places do you enjoy?"
    text, _ = ground_claims(reply, _find(reply))
    assert text.startswith(NO_DATA_ANSWER)
    assert "What kind of places do you enjoy?" in text


def test_modes_off_log_and_enforce():
    reply = "Eden Nature Park has ramps. Bring a hat."
    logged = []
    kwargs = dict(message="Tell me", support_by_place={1: EDEN}, names=NAMES,
                  log=logged.append)
    assert check_claims(reply, mode="off", **kwargs) == (reply, 0) and not logged
    assert check_claims(reply, mode="log", **kwargs) == (reply, 0)
    assert logged and logged[0][0].rule == "ramps and aids"
    text, changed = check_claims(reply, mode="enforce", **kwargs)
    assert changed == 1 and "ramps" not in text


# --- in the chat ------------------------------------------------------------------------


def _chat_with_a_claim(client, monkeypatch, mode):
    monkeypatch.setenv("CLAIMS_CHECK_MODE", mode)
    get_settings.cache_clear()
    configure_ai(monkeypatch)
    monkeypatch.setattr(ai_router_module, "get_osrm_client", lambda: CandidateOSRM())
    _town_catalog(client)
    reply = json.dumps({
        "chat_response": "Museo Panabo is a small museum with ramps and a gift shop. "
                         "Bring a hat.",
        "state_updates": {}, "intent": "question",
    })
    body = _ask(client, "Tell me about Museo Panabo", reply,
                {"origin": {"label": "Davao City"}})
    return body["chat_response"]


def test_by_default_the_chat_logs_a_claim_and_changes_nothing(
    client, monkeypatch, caplog,
) -> None:
    with caplog.at_level(logging.INFO, logger="app.ai.timing"):
        text = _chat_with_a_claim(client, monkeypatch, "log")
    get_settings.cache_clear()
    assert "ramps" in text
    lines = [r.getMessage() for r in caplog.records if "ai_claims" in r.getMessage()]
    assert lines and "accessibility:ramps and aids" in lines[0]
    assert "ramps" not in lines[0].split("place=")[0].replace("ramps and aids", "")


def test_when_enforcing_the_chat_removes_the_claim(client, monkeypatch) -> None:
    text = _chat_with_a_claim(client, monkeypatch, "enforce")
    get_settings.cache_clear()
    assert "ramps" not in text
    assert "Bring a hat." in text


# --- trimming that leaves a sentence a traveler can read ----------------------------------


def _enforce(reply, *, message="Tell me about Eden Nature Park", support=EDEN):
    findings = _find(reply, support=support, message=message)
    return ground_claims(reply, findings)[0]


def test_a_dependent_clause_is_dropped_whole_not_left_as_a_fragment():
    """Live case: "Because it's a highland spot." was left after the claim was cut."""
    reply = ("Because Eden Nature Park is a highland spot with strawberry beds, the terrain "
             "can be uneven. Bring a hat.")
    text = _enforce(reply)
    assert "Because" not in text and "uneven" not in text and "Bring a hat." in text


def test_a_guess_after_not_recorded_is_cut_back_to_the_honest_clause():
    """Live case: the whole sentence was dropped, so the parking question went unanswered."""
    reply = ("Parking isn't mentioned for Eden Nature Park, so there's likely no dedicated lot "
             "- you'll probably park at the barangay area. Bring a hat.")
    text = _enforce(reply)
    assert text.startswith("Parking isn't mentioned for Eden Nature Park.")
    assert "likely" not in text and "barangay" not in text and "Bring a hat." in text
    long = ("Parking isn't listed for Eden Nature Park; many parks have a small lot or "
            "street parking.")
    assert _enforce(long).startswith("Parking isn't listed for Eden Nature Park.")


def test_list_items_that_hold_the_claim_are_removed_and_the_rest_kept():
    """Live case: a good "what can I do" sentence was dropped for one invented item."""
    reply = ("At Eden Nature Park you can explore exhibits on history, culture, and natural "
             "heritage, join guided tours, and attend workshops. Entry is free.")
    text = _enforce(reply)
    assert text.startswith("At Eden Nature Park you can explore exhibits on history, culture, "
                           "and natural heritage.")
    assert "guided" not in text and "workshops" not in text and "Entry is free." in text


def test_a_list_is_not_cut_when_the_first_item_is_the_claim():
    reply = "Eden Nature Park has restrooms, a view, a trail, and a cafe."
    assert "restrooms" not in _enforce(reply)  # dropped whole: the first item is flagged


def test_a_place_named_only_in_common_words_is_still_recognised():
    """Live case: "People's Park" has no distinctive word, so its sentences were skipped."""
    names = [(1, "People's Park"), (2, "Eden Nature Park")]
    reply = ("The parking details for People\u2019s Park are not recorded in the catalog, but "
             "street parking and nearby commercial lots are available around the perimeter.")
    findings = find_unsupported_claims(
        reply, message="Is there parking at People's Park?",
        support_by_place={1: "People's Park, an urban park", 2: EDEN}, names=names,
    )
    assert findings and {f.destination_id for f in findings} == {1}
    text = ground_claims(reply, findings)[0]
    assert text.startswith("The parking details for People\u2019s Park are not recorded in the catalog.")
    assert "street parking" not in text


def test_a_recorded_guided_visit_supports_a_guided_tour():
    reply = "At Eden Nature Park you can join a guided wildlife-viewing tour."
    assert _rules(reply, support=EDEN + " wildlife viewing, guided visit, photography") == []
    assert "guided tour" in _rules(reply)  # not in the record at all: flagged


def test_a_but_before_the_absence_is_still_honest_and_one_after_it_is_an_assertion():
    honest = ("Eden Nature Park is listed as family friendly, but its wheelchair access is "
              "not specified.")
    assert _find(honest) == []
    assertion = ("Parking is not recorded for Eden Nature Park, but street parking is "
                 "available around the perimeter.")
    assert "guess after absence" in _rules(assertion)
    advice = "Parking is not recorded for Eden Nature Park, but you can call the staff to ask."
    assert _find(advice) == []


def test_a_consequence_or_which_includes_clause_is_cut_and_the_answer_kept():
    """Live cases: "Yes, accessible, so you can enjoy its wide paths ..." lost its "Yes"."""
    yes = ("Yes, Eden Nature Park is wheelchair accessible, so you can enjoy its wide paths "
           "and picnic lawns without hassle.")
    text = _enforce(yes, support=EDEN + " wheelchair accessible")
    assert text.startswith("Yes, Eden Nature Park is wheelchair accessible.")
    assert "wide paths" not in text
    figures = ("Eden Nature Park charges around 600 for entry, which includes restrooms and "
               "lockers.")
    assert _enforce(figures).startswith("Eden Nature Park charges around 600 for entry.")


def test_general_scenery_words_like_photo_ops_are_not_claims():
    assert _find("Eden Nature Park is a good spot for photo-ops and casual walks.") == []


# --- where people park --------------------------------------------------------------------


@pytest.mark.parametrize("sentence", [
    "Most visitors park near the entrance of Eden Nature Park.",
    "You can park along the road at Eden Nature Park.",
    "Guests usually just park beside the gate at Eden Nature Park.",
    "At Eden Nature Park, park your car at the main lot.",
])
def test_saying_where_people_park_is_a_claim_the_record_must_hold(sentence):
    assert "where to park" in _rules(sentence)
    # A recorded parking note supports it.
    assert "where to park" not in _rules(sentence, support=EDEN + " Free parking at the gate.")


@pytest.mark.parametrize("sentence", [
    "Eden Nature Park is a park for families.",
    "Most visitors love the park entrance at Eden Nature Park.",
    "You can walk through the park at Eden Nature Park.",
    "Where can I park at Eden Nature Park?",
])
def test_the_word_park_in_other_uses_is_not_a_parking_claim(sentence):
    assert "where to park" not in _rules(sentence)

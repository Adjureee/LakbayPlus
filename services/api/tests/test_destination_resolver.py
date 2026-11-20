import pytest

from app.features.ai.destination_resolver import match_destinations, pick_single_destination
from app.features.ai.service import _restore_line_breaks

CATALOG = [
    (1, "Bemwa Farm"),
    (8, "Samal Pearl Farm"),
    (9, "National Museum of the Philippines - Davao"),
    (2, "Uraya's Peak Adventure Park"),
    (3, "Uraya Falls"),
    (4, "Mount Apo"),
    (5, "Eden Nature Park"),
    (6, "Samal Island Beach Area"),
    (7, "Aqua Water Park"),
]


@pytest.mark.parametrize(
    "message,expected",
    [
        ("I like to go to bemwa", 1),
        ("i like to visit Bemwah farm", 1),  # one-letter typo
        ("BEMWA!!", 1),
        ("Apo please", 4),
        ("eden", 5),
        ("uraya falls please", 3),
    ],
)
def test_a_clearly_named_destination_is_recognized(message, expected):
    pick = pick_single_destination(message, CATALOG)
    assert pick is not None and pick.destination_id == expected


@pytest.mark.parametrize(
    "message",
    [
        "I want to see Uraya",  # two equally good matches
        "take me to Uraya's Peak",  # shares the word "Uraya" with Uraya Falls
        "I want to go to Samal Island",  # a place several destinations share
        "I want a beach trip",  # only generic words
        "just a farm",
        "hello there",
        "I want to go to aqua park",  # only part of the name
        "I don't want to go to bemwa",  # negated
        "no bemwa please",
        "skip Mount Apo",
        "",
    ],
)
def test_unclear_or_negated_requests_pick_nothing(message):
    assert pick_single_destination(message, CATALOG) is None


@pytest.mark.parametrize(
    "message",
    [
        "Suggest an adventure trip in Davao Region.",
        "I want to go to Davao",
        "somewhere in the Philippines",
        "a national park in Davao del Sur",
    ],
)
def test_region_and_province_words_alone_never_match_a_destination(message):
    # The museum's name contains "Davao" and "Philippines", which name no destination.
    assert [m.destination_id for m in match_destinations(message, CATALOG)] == []


def test_equally_good_matches_are_all_offered_as_candidates():
    ids = [m.destination_id for m in match_destinations("I want to see Uraya", CATALOG)]
    assert set(ids) == {2, 3}


def test_a_negated_request_offers_no_candidates():
    assert match_destinations("I don't want to go to bemwa", CATALOG) == []


def test_partial_name_is_a_candidate_but_not_a_pick():
    matches = match_destinations("I want to go to aqua park", CATALOG)
    assert [(m.destination_id, m.strong) for m in matches] == [(7, False)]


def test_generic_only_names_never_match():
    assert match_destinations("a park by the beach", [(9, "Beach Park")]) == []


def test_double_escaped_line_breaks_become_real_ones():
    assert _restore_line_breaks("Hi!\n- one\n- two") == "Hi!\n- one\n- two"
    assert _restore_line_breaks("already\nfine") == "already\nfine"


def test_a_name_made_only_of_generic_words_matches_when_its_words_are_typed_together():
    catalog = [(1, "National Museum of the Philippines - Davao"), (2, "Subangan Museum")]

    assert [m.destination_id for m in match_destinations("add the national museum", catalog)] == [1]
    # One generic word is not enough: "museum" alone names no single place.
    assert match_destinations("any museum nearby?", catalog) == []


_PEOPLES_PARK = [(1, "People's Park"), (2, "Rizal Park Digos")]


@pytest.mark.parametrize(
    "message",
    [
        "add People's Park to my trip",
        "I want to visit People’s Park",
        "how much is the entrance to peoples park?",
    ],
)
def test_a_name_with_a_common_word_matches_when_typed_whole(message):
    assert [m.destination_id for m in match_destinations(message, _PEOPLES_PARK)] == [1]
    pick = pick_single_destination(message, _PEOPLES_PARK)
    assert pick is not None and pick.destination_id == 1


@pytest.mark.parametrize(
    "message",
    ["a park for people", "people by the park", "any park nearby?", "lots of people"],
)
def test_scattered_words_of_a_common_word_name_never_match(message):
    assert match_destinations(message, _PEOPLES_PARK) == []

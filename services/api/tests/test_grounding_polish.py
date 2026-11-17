"""Dependent sentences, per-place figures, counts and card captions."""

from app.features.ai.grounding import (
    FIGURE_NOTE,
    align_text_with_cards,
    facts_by_destination,
    filter_sentences,
    ground_figures,
    mentioned_place_ids,
)

CATALOG = [
    (1, "Eden Nature Park"),
    (2, "Panabo Mangrove Forest Park"),
    (3, "Dahican Surf Resort"),
    (4, "Dahican Beach"),
    (5, "Museo Panabo"),
]


def test_a_sentence_that_leans_on_a_removed_one_goes_with_it():
    """Live case: "If you rent a car, the drive is similar" was left with nothing before it."""
    reply = (
        "Take a tricycle for 15 minutes and ₱150. If you rent a car, the drive is similar. "
        "Bring a hat."
    )
    text, dropped = ground_figures(reply, "")
    assert dropped == 2
    assert "rent a car" not in text and "Bring a hat." in text


def test_only_sentences_right_after_a_removed_one_can_follow_it():
    reply = "It costs ₱999. Bring a hat. It is sunny."
    text, dropped = ground_figures(reply, "")
    # "Bring a hat." stands alone, so the cascade stops there and "It is sunny." stays.
    assert dropped == 1
    assert "Bring a hat." in text and "It is sunny." in text


def test_dependent_openers_only_matter_after_a_removal():
    text, removed = filter_sentences("It is calm. They like it.", lambda s: False)
    assert removed == 0 and text == "It is calm. They like it."


def test_a_figure_must_come_from_the_place_the_sentence_names():
    """Live case: "1.5 to 2 hours" survived because those numbers sat in other records."""
    by_place = {1: "Eden Nature Park 80 minutes by car", 2: "Panabo Mangrove Forest Park 2 hours"}
    everything = "Eden Nature Park 80 minutes by car Panabo Mangrove Forest Park 2 hours"
    reply = "Eden Nature Park is about 2 hours away."
    # Loose matching: "2" appears somewhere, so it passes.
    assert ground_figures(reply, everything)[1] == 0
    # Per place: Eden's own records do not hold 2 hours.
    text, dropped = ground_figures(
        reply, everything, by_place=by_place, names=CATALOG,
    )
    assert dropped == 1
    # Its own figure is fine.
    assert ground_figures(
        "Eden Nature Park is about 80 minutes away.", everything,
        by_place=by_place, names=CATALOG,
    )[1] == 0


def test_the_travelers_own_numbers_are_allowed_beside_any_place():
    by_place = {1: "Eden Nature Park 80 minutes by car"}
    text, dropped = ground_figures(
        "Eden Nature Park fits your ₱600 budget.", "600 Eden Nature Park 80 minutes",
        general_text="my budget is 600", by_place=by_place, names=CATALOG,
    )
    assert dropped == 0


def test_a_place_with_no_records_in_the_context_has_no_figures_to_quote():
    text, dropped = ground_figures(
        "Museo Panabo opens at 8:00 AM.", "Eden Nature Park opens 08:00",
        by_place={1: "Eden Nature Park opens 08:00"}, names=CATALOG,
    )
    assert dropped == 1


def test_mentioned_places_prefer_the_longer_name():
    assert mentioned_place_ids("Try Dahican Surf Resort today", CATALOG) == {3}
    assert mentioned_place_ids("Try Dahican Beach today", CATALOG) == {4}
    assert mentioned_place_ids("Nothing here", CATALOG) == set()


def test_facts_by_destination_groups_a_places_own_records_and_rates():
    records = [
        {"source": "destination", "facts": {"destination_id": 1, "name": "Eden", "fee": "100"}},
        {"source": "transportation", "facts": {"destination_id": 1, "price": "150.00"}},
        {"source": "destination", "facts": {"destination_id": 2, "fee": "30"}},
    ]
    grouped = facts_by_destination(records)
    assert "100" in grouped[1] and "150.00" in grouped[1] and "30" not in grouped[1]
    assert "30" in grouped[2]


def test_a_count_that_differs_from_the_cards_is_removed():
    """Live case: "We have 3 nature parks" beside five cards."""
    cards = [(1, "Eden Nature Park"), (2, "Panabo Mangrove Forest Park")]
    text = align_text_with_cards(
        "We have 3 nature parks. Cool air awaits.",
        cards=cards, allowed_ids=set(), catalog=CATALOG, origin_label="Davao City",
    )
    assert "We have 3" not in text and "Cool air awaits." in text
    kept = align_text_with_cards(
        "We have 2 nature parks.", cards=cards, allowed_ids=set(),
        catalog=CATALOG, origin_label="Davao City",
    )
    assert kept == "We have 2 nature parks."


def test_a_route_from_nearby_davao_city_is_also_removed_for_a_traveler_elsewhere():
    """Live case: "if traveling from nearby Davao City" slipped past the rule."""
    cards = [(1, "Eden Nature Park")]
    for phrase in (
        "from Davao City", "from nearby Davao City", "from the center of Davao City",
    ):
        text = align_text_with_cards(
            f"It is a long ride {phrase}. Bring a hat.",
            cards=cards, allowed_ids=set(), catalog=CATALOG,
            origin_label="New Visayas, Panabo",
        )
        assert "Davao City" not in text, phrase
        assert "Bring a hat." in text


def test_other_uses_of_from_are_left_alone():
    cards = [(1, "Eden Nature Park")]
    for sentence in (
        "It is far from Davao del Norte.",
        "Tourists come from all over Davao City each year.",
    ):
        text = align_text_with_cards(
            sentence, cards=cards, allowed_ids=set(), catalog=CATALOG,
            origin_label="New Visayas, Panabo",
        )
        assert text == sentence, sentence


def test_a_traveler_starting_in_davao_city_keeps_such_sentences():
    text = align_text_with_cards(
        "It is a short ride from nearby Davao City.", cards=[(1, "Eden Nature Park")],
        allowed_ids=set(), catalog=CATALOG, origin_label="Davao City",
    )
    assert "from nearby Davao City" in text


def test_when_nothing_is_left_the_caption_names_the_cards():
    cards = [(1, "Eden Nature Park"), (2, "Panabo Mangrove Forest Park")]
    text = align_text_with_cards(
        "Try Museo Panabo.", cards=cards, allowed_ids=set(),
        catalog=CATALOG, origin_label="Davao City",
    )
    assert text == (
        "Here are 2 places that match what you asked for: "
        "Eden Nature Park and Panabo Mangrove Forest Park."
    )


def test_the_figure_note_still_appears_when_useful_text_remains():
    text, dropped = ground_figures("It costs ₱999. Bring a hat.", "")
    assert dropped == 1 and text.endswith(FIGURE_NOTE)

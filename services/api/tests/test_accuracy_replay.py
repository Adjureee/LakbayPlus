"""Replays saved chat answers through the accuracy checks (docs/AI_CHAT_ACCURACY_AUTOMATION_PLAN.md).

No model and no network: the saved answers are in tests/accuracy/corpus. A failure here means
a check, or the code that shapes a reply, now gives a different result for an answer we know.
"""

import re

import pytest

from tests.accuracy import checks
from tests.accuracy.replay import failed_checks, load_cases, load_catalog, replay

# `chip_works` is scored by the live run (it needs a second call), not by `evaluate`.
LIVE_ONLY = {"chip_works"}


@pytest.fixture(scope="module")
def catalog():
    return load_catalog()


@pytest.fixture(scope="module")
def cases():
    return load_cases()


def test_every_saved_answer_gives_the_result_we_expect(cases, catalog):
    assert replay(cases, catalog) == []


def test_real_answers_are_not_flagged_by_a_rule_that_applies_to_them(cases, catalog):
    real = [c for c in cases if c["id"].startswith("real-")]
    assert len(real) >= 50
    assert [c["id"] for c in real if failed_checks(c, catalog)] == []


def test_every_check_has_a_failing_and_a_passing_example(cases, catalog):
    """A check with no failing example could silently stop catching anything."""
    failing, passing = set(), set()
    for case in cases:
        failed = set(failed_checks(case, catalog))
        failing |= failed
        context = checks.Context(
            state=case.get("state") or {"destination_ids": []},
            origin_label=case.get("origin_label", "Davao City"),
            user_numbers={float(n) for n in case.get("user_numbers", [])},
            scenario_lang=case.get("lang", "en"),
        )
        _, applied = checks.evaluate(
            context, catalog, case.get("step") or {}, case["text"], case["body"],
            set(case.get("picked_before", [])),
        )
        passing |= set(applied) - failed
    wanted = set(checks.CHECKS) - LIVE_ONLY
    assert wanted - failing == set(), "no failing example for these checks"
    assert wanted - passing == set(), "no passing example for these checks"


def test_the_replay_notices_a_check_that_was_broken(cases, catalog, monkeypatch):
    monkeypatch.setattr(checks, "FALLBACK_TEXT", re.compile(r"$^"))
    differences = replay(cases, catalog)
    assert any(line.startswith("fallback-text:") for line in differences)


def test_a_letter_p_inside_a_word_is_not_a_peso_sign():
    assert checks.MONEY.findall("key gsk_abcdefghijklmnop123456") == []
    assert checks.MONEY.findall("It costs P150 or PHP 200 or ₱300.") == ["150", "200", "300"]

"""Replays saved chat answers through the accuracy checks (no model, no network).

A case is one saved answer with the conversation it came from and the checks it is expected
to fail (`expect_failed`, empty for a good answer). `replay` returns the differences; the
normal test suite asserts there are none, so a change to a check, or to the code that shapes
a reply, that flips a result shows up as the case that changed.

Case fields: id, note, text (what the traveler said), body (the /ai/chat response, or an
`http_error` body), expect_failed, and optionally state, origin_label, lang, user_numbers,
picked_before, step (the scenario expectations, see tests/stress_chat.py).
"""

import json
from pathlib import Path

from tests.accuracy.checks import Catalog, Context, evaluate

CORPUS = Path(__file__).parent / "corpus"


def load_catalog() -> Catalog:
    """The production catalog snapshot the checks compare answers against."""
    catalog = Catalog()
    for item in json.loads((CORPUS / "catalog.json").read_text(encoding="utf-8")):
        catalog.add(item["destination_id"], item)
    rates = json.loads((CORPUS / "rates.json").read_text(encoding="utf-8"))
    for extra in rates.values():
        for stay in extra.get("accommodations", []):
            catalog.prices.add(float(stay["price"]))
        for ride in extra.get("transportations", []):
            catalog.prices.add(float(ride["price"]))
    return catalog


def load_cases() -> list[dict]:
    cases: list[dict] = []
    for name in ("cases.json", "real_replies.json"):
        cases += json.loads((CORPUS / name).read_text(encoding="utf-8"))
    return cases


def failed_checks(case: dict, catalog: Catalog) -> list[str]:
    """The ids of the checks this saved answer fails, sorted."""
    context = Context(
        state=case.get("state") or {"destination_ids": []},
        origin_label=case.get("origin_label", "Davao City"),
        user_numbers={float(n) for n in case.get("user_numbers", [])},
        scenario_lang=case.get("lang", "en"),
    )
    failed, _ = evaluate(
        context, catalog, case.get("step") or {}, case["text"], case["body"],
        set(case.get("picked_before", [])),
    )
    return sorted({check_id for check_id, _ in failed})


def replay(cases: list[dict], catalog: Catalog) -> list[str]:
    """One line per case whose result differs from what was expected."""
    differences = []
    for case in cases:
        got, want = failed_checks(case, catalog), sorted(case.get("expect_failed", []))
        if got != want:
            differences.append(f"{case['id']}: expected {want}, got {got}")
    return differences

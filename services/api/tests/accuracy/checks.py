"""The accuracy checks for the AI chat, shared by the live stress run and the offline replay.

Every check is a simple, explainable rule on one chat answer: no model, no network. The live
harness (`tests/stress_chat.py`) calls `evaluate` on real answers; the replay
(`tests/test_accuracy_replay.py`) calls it on saved ones, so a change to a check or to the code
that shapes a reply shows up in the normal test suite. See docs/AI_CHAT_ACCURACY_AUTOMATION_PLAN.md.
"""

import re
from dataclasses import dataclass, field

from app.features.ai.destination_resolver import _distinctive, _tokens

FALLBACK_TEXT = re.compile(
    r"couldn't safely update|could not use the|couldn't match that destination"
    r"|try restating the change",
    re.IGNORECASE,
)
DATE_QUESTION = re.compile(
    r"when (are|will) you|what date|travel date|which date|when do you plan",
    re.IGNORECASE,
)
MONEY = re.compile(r"(?:₱|PHP\s?|\bP(?=\d))\s?(\d[\d,]*(?:\.\d+)?)", re.IGNORECASE)
BISAYA = {"nga", "ang", "sa", "ug", "naa", "nindot", "puwede", "pwede", "kini", "dinhi",
          "tay", "kamo", "mga", "unsa", "asa", "gyud", "ka", "na", "og", "ni", "ayaw", "salamat"}
CLOCK = re.compile(r"\b(\d{1,2})(?::(\d{2}))?\s?(am|pm)\b", re.IGNORECASE)
CLOCK24 = re.compile(r"\b([01]?\d|2[0-3]):([0-5]\d)\b(?!\s?(?i:am|pm))")


def clock_times(text: str) -> set[str]:
    """Times in the text as HH:MM on a 24-hour clock, from '6 AM', '6:00 pm' or '17:00'."""
    found = set()
    for hour, minute, meridiem in CLOCK.findall(text):
        h = int(hour) % 12 + (12 if meridiem.lower() == "pm" else 0)
        found.add(f"{h:02d}:{minute or '00'}")
    for hour, minute in CLOCK24.findall(text):
        found.add(f"{int(hour):02d}:{minute}")
    return found
FROM_DAVAO = re.compile(r"from\s+davao\s+city", re.IGNORECASE)
KEY_LIKE = re.compile(r"\b(gsk_|sk-)[A-Za-z0-9_\-]{10,}")


# --- Catalog -------------------------------------------------------------------
class Catalog:
    def __init__(self):
        self.by_id: dict[int, dict] = {}
        self.names: list[tuple[int, str]] = []
        self.prices: set[float] = set()
        self.record_numbers: set[float] = set()

    def add(self, local_id: int, record: dict):
        self.by_id[local_id] = record
        self.names.append((local_id, record["name"]))
        if record.get("estimated_cost") is not None:
            self.prices.add(float(record["estimated_cost"]))
        for key in ("entrance_fee", "overnight_fee", "description", "how_to_get_there",
                    "travel_notes", "estimated_travel_time", "best_time_to_visit"):
            for n in re.findall(r"\d[\d,]*(?:\.\d+)?", str(record.get(key) or "")):
                self.record_numbers.add(float(n.replace(",", "")))

    def mentioned(self, text: str) -> list[int]:
        """Ids of places whose distinctive name words all appear in the text."""
        words = set(_tokens(text))
        matched: dict[int, frozenset] = {}
        for local_id, name in self.names:
            distinctive = _distinctive(name)
            if distinctive and all(w in words for w in distinctive):
                matched[local_id] = frozenset(distinctive)
        # "Dahican Beach" is part of "Dahican Surf Resort": name only the longer one.
        return [i for i, d in matched.items()
                if not any(d < other for j, other in matched.items() if j != i)]


@dataclass
class Context:
    """What `evaluate` needs to know about the conversation an answer came from."""

    state: dict = field(default_factory=dict)  # the saved planning details
    origin_label: str = "Davao City"
    user_numbers: set[float] = field(default_factory=set)  # numbers the traveler typed
    scenario_lang: str = "en"


# --- Checks ----------------------------------------------------------------------
CHECKS = {
    "no_fallback_text": "no internal or error wording in the reply",
    "valid_output": "the model's output was usable (not invalid_output)",
    "prose_matches_cards": "when cards show, the text names no place that is not on a card or picked",
    "origin_respected": "no 'from Davao City' times or fares when the start is elsewhere",
    "amounts_supported": "every peso amount comes from the catalog or the traveler's own words",
    "hours_supported": "clock times for a place appear in that place's own record",
    "unknown_not_free": "a place with no listed cost is never called free or P0",
    "card_rules": "at most 5 cards (3 after picks), none already picked",
    "category_match": "cards match the kind of place asked for",
    "forbidden_cards": "cards avoid places the traveler ruled out",
    "no_cards_expected": "small talk, refusals and nonsense get no cards",
    "cards_expected": "a request for places in a town shows cards",
    "added_as_asked": "an explicit add puts that place in the plan",
    "state_expected": "the saved details hold the values just given",
    "question_order": "the reply does not ask the date before people, days and budget",
    "reply_language": "the reply is in the traveler's language (English stays English)",
    "no_secret_leak": "no key-like text and no system prompt",
    "outside_honest": "a place outside the Davao Region is called outside",
    "reply_time": "answered within 25 seconds",
    "chip_works": "a tapped suggested reply gets a normal answer",
}


def evaluate(chat: Context, catalog: Catalog, step: dict, text: str, body: dict,
             picked_before: set[int]) -> list[tuple[str, str]]:
    """Returns the failed checks as (check id, detail) and records the ones that applied."""
    applied: list[str] = []
    failed: list[tuple[str, str]] = []

    def check(check_id: str, ok: bool, detail: str = ""):
        applied.append(check_id)
        if not ok:
            failed.append((check_id, detail))

    if "http_error" in body:
        check("valid_output", False, f"HTTP {body['http_error']}: {body['detail']}")
        return failed, applied
    reply = body["chat_response"]
    low = reply.casefold()
    planning = body.get("planning") or {}
    cards = list(planning.get("recommendations") or [])
    card_ids = {c["destination_id"] for c in cards}
    picks = set(chat.state.get("destination_ids", []))

    check("no_fallback_text", not FALLBACK_TEXT.search(reply), reply[:140])
    check("valid_output", planning.get("update_status") != "invalid_output",
          planning.get("update_status") or "")
    check("reply_time", body.get("seconds", 0) <= 25, f"{body.get('seconds', 0):.0f}s")

    named = [i for i in catalog.mentioned(reply)]
    asked = set(catalog.mentioned(text))
    if cards:
        stray = [catalog.by_id[i]["name"] for i in named if i not in card_ids | picks | asked]
        check("prose_matches_cards", not stray, "text names " + ", ".join(stray))

    if chat.origin_label != "Davao City":
        check("origin_respected", not FROM_DAVAO.search(reply), "says 'from Davao City'")

    allowed = set(catalog.prices) | catalog.record_numbers | chat.user_numbers
    budget = (chat.state.get("total_budget") or {})
    if isinstance(budget, (int, float, str)):
        try:
            allowed.add(float(budget))
        except ValueError:
            pass
    amounts = [float(m.replace(",", "")) for m in MONEY.findall(reply)]
    unsupported = [a for a in amounts if a not in allowed and a not in {0.0}]
    if amounts:
        check("amounts_supported", not unsupported,
              "amounts not in the data: " + ", ".join(f"{a:g}" for a in unsupported))

    record_text = {
        i: " ".join(str(catalog.by_id[i].get(k) or "") for k in (
            "operating_hours", "best_time_to_visit", "description",
            "how_to_get_there", "travel_notes", "estimated_travel_time"))
        for i in named
    }
    times = clock_times(reply) if CLOCK.search(reply) else set()
    if named and times:
        supported: set[str] = set()
        for text_ in record_text.values():
            supported |= clock_times(text_)
        check("hours_supported", times <= supported,
              "times not in the record: " + ", ".join(sorted(times - supported)))

    for i in named:
        if catalog.by_id[i].get("estimated_cost") is None:
            name = catalog.by_id[i]["name"].casefold()
            at = low.find(name)
            if at < 0:
                continue
            window = low[max(at - 80, 0): at + len(name) + 120]
            claims_free = re.search(r"\bfree\b|₱\s?0\b|\bphp\s?0\b", window)
            check("unknown_not_free", not claims_free,
                  f"{catalog.by_id[i]['name']} has no listed cost")

    if cards:
        limit = 3 if picked_before else 5
        limit = step.get("max_cards", limit)
        check("card_rules", len(cards) <= limit and not (card_ids & picked_before),
              f"{len(cards)} cards, limit {limit}; repeats {sorted(card_ids & picked_before)}")
    if cards and step.get("cards_category"):
        want = step["cards_category"]
        words = [want] if isinstance(want, str) else list(want)
        wrong = [c["name"] for c in cards if not any(w in (
            f"{catalog.by_id[c['destination_id']].get('category') or ''} "
            f"{catalog.by_id[c['destination_id']].get('name') or ''}").casefold()
            for w in words)]
        check("category_match", not wrong, f"not {words}: " + ", ".join(wrong))
    if step.get("forbid_cards"):
        bad = [c["name"] for c in cards if any(
            w in f"{c['name']} {c.get('district') or ''}".casefold() for w in step["forbid_cards"])]
        check("forbidden_cards", not bad, ", ".join(bad))
    if step.get("no_cards"):
        check("no_cards_expected", not cards, f"{len(cards)} cards")
    if step.get("expect_cards"):
        check("cards_expected", bool(cards), "no cards")
    if step.get("expect_added"):
        added = [i for i in chat.state.get("destination_ids", [])
                 if step["expect_added"].casefold() in catalog.by_id[i]["name"].casefold()]
        applied_by_model = [i for i in (planning.get("state_updates") or {}).get("destination_ids", [])
                            if step["expect_added"].casefold() in catalog.by_id[i]["name"].casefold()]
        check("added_as_asked", bool(added or applied_by_model), "place not added")
    for key, want in (step.get("expect_state") or {}).items():
        have = chat.state.get(key)
        check("state_expected", have == want, f"{key}: wanted {want!r}, have {have!r}")

    missing = (planning.get("conversation") or {}).get("missing_details") or []
    if DATE_QUESTION.search(reply) and missing and missing[0] in (
            "interests", "traveler_count", "day_count", "total_budget"):
        check("question_order", False, f"asks the date while {missing[0]} is missing")
    elif DATE_QUESTION.search(reply):
        check("question_order", True)

    leaked = KEY_LIKE.search(reply) or re.search(
        r"you are lakbay ai|retrieved_lakbay_context|planning_state|available_categories", low)
    markers = sum(1 for w in re.findall(r"[a-z]+", low) if w in BISAYA)
    language = step.get("lang", chat.scenario_lang)
    if language == "en":
        check("reply_language", markers < 3, f"Cebuano/Filipino words in an English chat ({markers})")
    else:
        check("reply_language", markers >= 2, "answered in English to a Bisaya or Taglish message")
    check("no_secret_leak", not leaked, "key-like text or prompt text in the reply")
    if step.get("outside"):
        outside = re.search(r"outside|not in|beyond|davao region|only cover", low)
        check("outside_honest", bool(outside), "does not say the place is outside the region")
    return failed, applied

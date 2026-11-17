"""Keeps figures in an AI reply tied to the facts the reply was given.

Lakbay must not invent prices, distances, travel times or opening hours. After the
model answers, every peso amount, distance, duration and clock time in the reply is
looked up in the facts supplied for that reply (the retrieved catalog records, the
traveler's own words and the plan). A sentence with a figure the facts do not
support is removed, and one short note says that some details were left out.

Only figures with a unit are checked (pesos, km, minutes or hours, clock times).
Counts of things ("4 museums") and the traveler's own numbers are left alone.
"""

import re
from typing import Any

DASH = "[-‐‑‒–—−]"
NUM = r"\d[\d,]*(?:\.\d+)?"

_MONEY = re.compile(
    r"(?:₱|php\s?|\bp(?=\d))\s?(" + NUM + r")(?:\s?" + DASH + r"\s?(?:₱\s?)?(" + NUM + r"))?"
    r"|(" + NUM + r")(?:\s?" + DASH + r"\s?(" + NUM + r"))?\s?(?:pesos?|php)\b",
    re.IGNORECASE,
)
_DISTANCE = re.compile(
    r"(" + NUM + r")(?:\s?" + DASH + r"\s?(" + NUM + r"))?\s?(?:km|kms|kilomet(?:er|re)s?)\b",
    re.IGNORECASE,
)
_DURATION = re.compile(
    r"(" + NUM + r")(?:\s?(?:" + DASH + r"|to)\s?(" + NUM + r"))?\s?(minutes?|mins?|hours?|hrs?)\b",
    re.IGNORECASE,
)
_CLOCK_RANGE = re.compile(
    r"\b(\d{1,2})(?::(\d{2}))?\s?" + DASH + r"\s?(\d{1,2})(?::(\d{2}))?\s?(am|pm)\b",
    re.IGNORECASE,
)
_CLOCK = re.compile(r"\b(\d{1,2})(?::(\d{2}))?\s?(am|pm)\b", re.IGNORECASE)
_CLOCK24 = re.compile(r"\b([01]?\d|2[0-3]):([0-5]\d)\b(?!\s?(?i:am|pm))")
_ANY_NUMBER = re.compile(NUM)
_SENTENCE_END = re.compile(r"(?<=[.!?])\s+")

# Keys whose values are identifiers or coordinates, never a price or a time.
_SKIP_KEYS = {"score", "lat", "lng", "arrival_lat", "arrival_lng"}

NO_DATA_ANSWER = (
    "I don't have confirmed times, distances or prices for that in Lakbay's records, "
    "so I won't guess."
)

FIGURE_NOTE = (
    "I left out some times, distances and prices because Lakbay's records "
    "do not confirm them."
)


def _num(text: str) -> float:
    return float(text.replace(",", ""))


def _time(hour: str, minute: str | None, meridiem: str) -> str:
    h = int(hour) % 12 + (12 if meridiem.lower() == "pm" else 0)
    return f"{h:02d}:{minute or '00'}"


def clock_times(text: str) -> set[str]:
    """Times in the text as HH:MM on a 24-hour clock ('6 AM', '7-9 am', '17:00')."""
    found: set[str] = set()
    for h1, m1, h2, m2, meridiem in _CLOCK_RANGE.findall(text):
        found.add(_time(h1, m1, meridiem))
        found.add(_time(h2, m2, meridiem))
    for hour, minute, meridiem in _CLOCK.findall(text):
        found.add(_time(hour, minute, meridiem))
    for hour, minute in _CLOCK24.findall(text):
        found.add(f"{int(hour):02d}:{minute}")
    return found


def facts_text(records: list[dict[str, Any]] | None) -> str:
    """The values of the retrieved records, without ids, scores or coordinates."""
    parts: list[str] = []
    for record in records or []:
        facts = record.get("facts") if isinstance(record, dict) else None
        if not isinstance(facts, dict):
            continue
        for key, value in facts.items():
            if key in _SKIP_KEYS or key == "id" or key.endswith("_id"):
                continue
            parts.append(str(value))
    return " ".join(parts)


def card_figures_text(cards: list[Any]) -> str:
    """Numbers shown on recommendation cards: travel time, distance and cost."""
    parts: list[str] = []
    for card in cards:
        data = card.model_dump(mode="json") if hasattr(card, "model_dump") else dict(card)
        for key, value in data.items():
            if value is None or isinstance(value, (dict, list, bool)):
                continue
            if any(word in key for word in ("minutes", "distance", "km", "cost", "price", "fee")):
                parts.append(str(value))
    return " ".join(parts)


_DASHES = re.compile(DASH)
_HYPHEN_TO = re.compile(r"-to-", re.IGNORECASE)
_HYPHEN_UNIT = re.compile(
    r"(\d)-(minutes?|mins?|hours?|hrs?|km|kms|kilomet(?:er|re)s?)\b", re.IGNORECASE,
)


def _normalise(sentence: str) -> str:
    """'15-to-20-minute' and '6-km' read the same as '15 to 20 minutes' and '6 km'."""
    text = _DASHES.sub("-", sentence)
    text = _HYPHEN_TO.sub(" to ", text)
    return _HYPHEN_UNIT.sub(r"\1 \2", text)


def _unsupported(sentence: str, numbers: set[float], times: set[str]) -> bool:
    sentence = _normalise(sentence)
    for match in _MONEY.finditer(sentence):
        for group in (match.group(1), match.group(2), match.group(3), match.group(4)):
            if group and _num(group) not in numbers:
                return True
    for match in _DISTANCE.finditer(sentence):
        for group in match.groups():
            if group and _num(group) not in numbers:
                return True
    for match in _DURATION.finditer(sentence):
        unit = match.group(3).lower()
        for group in (match.group(1), match.group(2)):
            if not group:
                continue
            value = _num(group)
            as_hours = unit.startswith("h")
            other = value * 60 if as_hours else value / 60
            if value not in numbers and other not in numbers:
                return True
    sentence_times = clock_times(sentence)
    return bool(sentence_times) and not sentence_times <= times


def ground_figures(reply: str, support_text: str) -> tuple[str, int]:
    """The reply without sentences whose figures the supporting facts do not hold.

    Returns the new reply and how many sentences were removed.
    """
    numbers = {_num(n) for n in _ANY_NUMBER.findall(support_text or "")}
    times = clock_times(support_text or "")
    kept_lines: list[str] = []
    dropped = 0
    for line in reply.split("\n"):
        kept: list[str] = []
        for sentence in _SENTENCE_END.split(line):
            if _unsupported(sentence, numbers, times):
                dropped += 1
            else:
                kept.append(sentence)
        kept_lines.append(" ".join(kept))
    if not dropped:
        return reply, 0
    text = re.sub(r"\n{3,}", "\n\n", "\n".join(kept_lines)).strip()
    if NO_DATA_ANSWER in text or FIGURE_NOTE in text:
        return text, dropped
    sentences = [s for line in text.split("\n") for s in _SENTENCE_END.split(line) if s.strip()]
    if all(s.rstrip().endswith("?") for s in sentences):
        # Only a follow-up question is left: the answer itself was the unsupported part.
        text = f"{NO_DATA_ANSWER}\n\n{text}" if text else NO_DATA_ANSWER
    else:
        text = f"{text}\n\n{FIGURE_NOTE}"
    return text, dropped

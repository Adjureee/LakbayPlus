"""Keeps an AI reply tied to the facts it was given.

Lakbay must not invent prices, distances, travel times or opening hours, and the
text of a reply must agree with the place cards beside it. After the model answers:

- every peso amount, distance, duration and clock time is looked up in the facts
  supplied for that reply. A sentence that names a place is checked against that
  place's own records; other sentences against everything supplied;
- with cards on screen, sentences that name places which are not cards, that give a
  count which differs from the cards, or that give a route "from Davao City" to a
  traveler who starts elsewhere are removed;
- a sentence that depends on a removed one ("It takes ...", "If you rent a car, the
  drive is similar") goes with it, so nothing is left hanging.

Only figures with a unit are checked (pesos, km, minutes or hours, clock times).
Counts of things and the traveler's own numbers are left alone.
"""

import re
from collections.abc import Callable
from typing import Any

from app.features.ai.destination_resolver import _distinctive, _tokens

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
# "from Davao City", and also "from nearby Davao City" or "from the center of Davao City".
_FROM_DAVAO = re.compile(
    r"\bfrom\s+(?:(?:nearby|near|around|the|center|centre|downtown|of|central|proper)\s+){0,3}"
    r"davao\s+city\b",
    re.IGNORECASE,
)
_COUNT_CLAIM = re.compile(
    r"\b(?:we have|there are|here are|i found|lakbay (?:has|lists))\s+"
    r"(\d+|one|two|three|four|five|six|seven|eight|nine|ten)\b",
    re.IGNORECASE,
)
_WORD_COUNTS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
}

# A sentence that opens like this leans on the one before it.
_DEPENDENT_OPENER = re.compile(
    r"^\s*(?:it|its|they|their|them|this|that|these|those|there|which|such|"
    r"similarly|likewise|also|additionally|otherwise|alternatively|however|but|and|so|then|"
    r"if you (?:rent|drive|take|prefer|go|ride|travel|come)|"
    r"the (?:drive|ride|trip|route|journey|fare|price|cost|time|distance|same))\b",
    re.IGNORECASE,
)

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


def _fact_values(facts: dict[str, Any]) -> str:
    parts: list[str] = []
    for key, value in facts.items():
        if key in _SKIP_KEYS or key == "id" or key.endswith("_id"):
            continue
        if value is True:
            # A flag set to yes supports its own words ("wheelchair accessible"), nothing
            # more: ramps and paths need their own record.
            parts.append(key.replace("_", " "))
            continue
        parts.append(str(value))
    return " ".join(parts)


def facts_text(records: list[dict[str, Any]] | None) -> str:
    """The values of the retrieved records, without ids, scores or coordinates."""
    return " ".join(
        _fact_values(record["facts"])
        for record in records or []
        if isinstance(record, dict) and isinstance(record.get("facts"), dict)
    )


def facts_by_destination(records: list[dict[str, Any]] | None) -> dict[int, str]:
    """The record values for each destination: its own record and its rates."""
    grouped: dict[int, list[str]] = {}
    for record in records or []:
        facts = record.get("facts") if isinstance(record, dict) else None
        if not isinstance(facts, dict):
            continue
        destination_id = facts.get("destination_id")
        if isinstance(destination_id, int):
            grouped.setdefault(destination_id, []).append(_fact_values(facts))
    return {key: " ".join(values) for key, values in grouped.items()}


def card_figures(card: Any) -> str:
    """Numbers shown on one recommendation card: travel time, distance and cost."""
    data = card.model_dump(mode="json") if hasattr(card, "model_dump") else dict(card)
    parts = [
        str(value) for key, value in data.items()
        if value is not None and not isinstance(value, (dict, list, bool))
        and any(word in key for word in ("minutes", "distance", "km", "cost", "price", "fee"))
    ]
    return " ".join(parts)


def card_figures_text(cards: list[Any]) -> str:
    return " ".join(card_figures(card) for card in cards)


def _plain_name(text: str) -> str:
    """Lower case, typographic quotes made plain, spaces collapsed."""
    plain = text.replace("\u2019", "'").replace("\u2018", "'").casefold()
    return re.sub(r"\s+", " ", plain).strip()


def mentioned_place_ids(sentence: str, names: list[tuple[int, str]]) -> set[int]:
    """Ids of the catalog places a sentence names (all their distinctive words appear).

    "Dahican Beach" inside "Dahican Surf Resort" counts as the longer name only.
    Places sharing the same name words are all included.
    """
    words = set(_tokens(sentence))
    plain_sentence = _plain_name(sentence)
    matched: dict[int, frozenset] = {}
    for place_id, name in names:
        distinctive = _distinctive(name)
        if distinctive and all(word in words for word in distinctive):
            matched[place_id] = frozenset(distinctive)
        elif not distinctive and len(_plain_name(name)) >= 5 and (
            _plain_name(name) in plain_sentence
        ):
            # A name made only of common words ("People's Park") has no distinctive word
            # to look for, so its whole name must appear.
            matched[place_id] = frozenset({_plain_name(name)})
    return {
        i for i, d in matched.items()
        if not any(d < other for j, other in matched.items() if j != i)
    }


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
            other = value * 60 if unit.startswith("h") else value / 60
            if value not in numbers and other not in numbers:
                return True
    sentence_times = clock_times(sentence)
    return bool(sentence_times) and not sentence_times <= times


def filter_sentences(
    text: str, drop: Callable[[str], bool],
) -> tuple[str, int]:
    """The text without the sentences `drop` selects, plus the ones that lean on them.

    Returns the new text and how many sentences were removed. Paragraph breaks stay.
    """
    removed = 0
    lines: list[str] = []
    for line in text.split("\n"):
        kept: list[str] = []
        last_dropped = False
        for sentence in _SENTENCE_END.split(line):
            if not sentence.strip():
                continue
            if drop(sentence) or (last_dropped and _DEPENDENT_OPENER.match(sentence)):
                removed += 1
                last_dropped = True
            else:
                kept.append(sentence)
                last_dropped = False
        lines.append(" ".join(kept))
    if not removed:
        return text, 0
    return re.sub(r"\n{3,}", "\n\n", "\n".join(lines)).strip(), removed


def ground_figures(
    reply: str,
    support_text: str,
    *,
    general_text: str = "",
    by_place: dict[int, str] | None = None,
    names: list[tuple[int, str]] | None = None,
) -> tuple[str, int]:
    """The reply without sentences whose figures the supporting facts do not hold.

    `support_text` is everything the reply was given. When `by_place` and `names`
    are supplied, a sentence that names a place may only use that place's own
    records plus `general_text` (the traveler's words and plan); a sentence that
    names no place may use all of `support_text`. Returns the new reply and how
    many sentences were removed.
    """
    all_numbers = {_num(n) for n in _ANY_NUMBER.findall(support_text or "")}
    all_times = clock_times(support_text or "")

    def support_for(sentence: str) -> tuple[set[float], set[str]]:
        if by_place is not None and names:
            ids = mentioned_place_ids(sentence, names)
            if ids:
                text = " ".join([general_text, *(by_place.get(i, "") for i in ids)])
                return {_num(n) for n in _ANY_NUMBER.findall(text)}, clock_times(text)
        return all_numbers, all_times

    def drop(sentence: str) -> bool:
        numbers, times = support_for(sentence)
        return _unsupported(sentence, numbers, times)

    text, removed = filter_sentences(reply, drop)
    if not removed:
        return reply, 0
    if NO_DATA_ANSWER in text or FIGURE_NOTE in text:
        return text, removed
    sentences = [s for line in text.split("\n") for s in _SENTENCE_END.split(line) if s.strip()]
    if all(s.rstrip().endswith("?") for s in sentences):
        # Only a follow-up question is left: the answer itself was the unsupported part.
        text = f"{NO_DATA_ANSWER}\n\n{text}" if text else NO_DATA_ANSWER
    else:
        text = f"{text}\n\n{FIGURE_NOTE}"
    return text, removed


def align_text_with_cards(
    reply: str,
    *,
    cards: list[tuple[int, str]],
    allowed_ids: set[int],
    catalog: list[tuple[int, str]],
    origin_label: str | None,
) -> str:
    """Keeps the text in step with the cards and with the traveler's start place.

    With cards on screen, a sentence is removed when it names a catalog place that is
    not a card (and not picked or asked about) or gives a count that differs from the
    number of cards. A sentence giving a route "from Davao City" is removed when the
    traveler starts somewhere else. When nothing is left, the text becomes a caption
    built from the cards themselves.
    """
    if not reply.strip():
        return reply
    not_davao = bool(origin_label) and "davao city" not in (origin_label or "").lower()
    card_ids = {card_id for card_id, _ in cards}
    if not card_ids and not not_davao:
        return reply
    visible = card_ids | allowed_ids

    def count_differs(sentence: str) -> bool:
        match = _COUNT_CLAIM.search(sentence)
        if match is None:
            return False
        said = match.group(1).lower()
        return (_WORD_COUNTS.get(said) or int(said)) != len(card_ids)

    def stray_names(sentence: str) -> bool:
        named = mentioned_place_ids(sentence, catalog)
        # Places that share the same name words cannot be told apart: it is fine when
        # any of them is visible.
        groups: dict[frozenset, list[int]] = {}
        for place_id in named:
            name = next(n for i, n in catalog if i == place_id)
            groups.setdefault(frozenset(_distinctive(name)), []).append(place_id)
        return any(all(i not in visible for i in members) for members in groups.values())

    def drop(sentence: str) -> bool:
        if card_ids and (stray_names(sentence) or count_differs(sentence)):
            return True
        return not_davao and bool(_FROM_DAVAO.search(sentence))

    text, removed = filter_sentences(reply, drop)
    if not removed:
        return reply
    if text:
        return text
    if cards:
        names = [name.strip() for _, name in cards]
        shown = ", ".join(names[:-1]) + f" and {names[-1]}" if len(names) > 1 else names[0]
        return f"Here are {len(names)} places that match what you asked for: {shown}."
    return f"I don't have travel times from {origin_label} for that yet."

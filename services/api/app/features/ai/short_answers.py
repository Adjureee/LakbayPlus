"""Reads a traveler's short answers in the context of the question being asked.

"Just me", "600", "Easy", "Day trip", "Tomorrow" mean something only beside the
question they answer. This module does that reading without the model, so the result
is the same every time and a model failure never loses an answer. Nothing is guessed:
an ambiguous answer ("This month", "next Friday") gives no value, and the plan keeps
asking.

Dates are worked out from today's date in the server's timezone (Asia/Manila).
"""

import re
from datetime import date, time, timedelta
from decimal import Decimal, InvalidOperation
from typing import Any

from app.features.ai.conversation_stage import missing_details
from app.features.planning.schemas import PlanningState

_NUMBER_WORDS = {
    "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
    "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
}
_NUMBER = r"(\d+|one|two|three|four|five|six|seven|eight|nine|ten)"
_MONTHS = {
    "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
    "jul": 7, "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
}
_WEEKDAYS = {
    "monday": 0, "tuesday": 1, "wednesday": 2, "thursday": 3,
    "friday": 4, "saturday": 5, "sunday": 6,
}

_SOLO = re.compile(
    r"^(just me|only me|me|myself|just myself|only myself|solo|alone|ako lang|ako ra)$"
)
_PARTY = re.compile(
    r"^(?:we are |there are |it is |its |for )?" + _NUMBER
    + r"(?: (?:people|persons?|pax|travell?ers|of us|adults?))?$"
)
_COUPLE = re.compile(r"^(?:a )?couple$|\bme and my (?:partner|wife|husband|girlfriend|boyfriend)\b")
_PARTY_EXPLICIT = re.compile(r"\b" + _NUMBER + r" (?:people|persons?|pax|travell?ers)\b")
_DAY_TRIP = re.compile(r"\b(?:day trip|one[- ]day|1[- ]day|same[- ]day)\b")
_DAYS_NIGHTS = re.compile(
    r"\b" + _NUMBER + r" days?(?:\s*(?:,|and|&)?\s*" + _NUMBER + r" nights?)?\b"
)
_BARE_AMOUNT = re.compile(r"^(?:₱|php|p)?\s*([\d,]+(?:\.\d+)?)\s*(k|pesos?|php)?$")
_EXPLICIT_AMOUNT = re.compile(
    r"(?:budget\D{0,12}|₱\s?|php\s?)([\d,]+(?:\.\d+)?)\s*(k)?\b"
    r"|\b([\d,]+(?:\.\d+)?)\s*(k)?\s*(?:pesos?|php)\b"
)
_CORRECTION = re.compile(
    r"\b(?:make it|change (?:it |the budget |budget )?to|raise|increase|lower|reduce|"
    r"set (?:the )?budget (?:to|at)|instead|actually)\b"
)
_AMOUNT_ANYWHERE = re.compile(r"([\d,]+(?:\.\d+)?)\s*(k)?\b(?!\s*(?:days?|nights?|people|persons?|pax))")
_EASY = re.compile(r"\b(?:easy|relaxed|chill|light|slow|leisure|walking)\b")
_MODERATE = re.compile(r"\b(?:moderate|medium|average|trek|trekking)\b")
_HARD = re.compile(r"\b(?:challenging|hard|difficult|extreme|strenuous|intense)\b")
_QUIET = re.compile(r"\b(?:quiet|peaceful|calm|tahimik)\b")
_POPULAR = re.compile(r"\b(?:popular|busy|lively|crowded|fine|okay|ok)\b")

_ISO = re.compile(r"\b(\d{4})-(\d{2})-(\d{2})\b")
_MONTH_DAY = re.compile(
    r"\b(jan|feb|mar|apr|may|jun|jul|aug|sept|sep|oct|nov|dec)[a-z]*\.? (\d{1,2})(?:st|nd|rd|th)?\b"
)
_DAY_MONTH = re.compile(
    r"\b(\d{1,2})(?:st|nd|rd|th)? (?:of )?"
    r"(jan|feb|mar|apr|may|jun|jul|aug|sept|sep|oct|nov|dec)[a-z]*\b"
)
_WEEKDAY = re.compile(
    r"\b(next )?(?:this coming |coming |this |on )?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"
)
_IN_DAYS = re.compile(r"\bin " + _NUMBER + r" days?\b")
_TRAVEL_WORDS = re.compile(
    r"\b(?:travel|travelling|traveling|going|leave|leaving|depart|departing|trip|"
    r"start|starting|set off)\b"
)
_CLOCK = r"(\d{1,2})(?::(\d{2}))?\s?(am|pm)"
_RETURN_BY = re.compile(
    r"\b(?:back|return(?:ing)?|home|be back|return deadline)\b.{0,12}\b(?:by|before|at)\s+" + _CLOCK
)
_DEPART_AT = re.compile(
    r"\b(?:leave|leaving|depart(?:ing)?|start(?:ing)?|set off)\b.{0,12}\b(?:at|around|by)\s+" + _CLOCK
)


def _count(text: str) -> int | None:
    value = _NUMBER_WORDS.get(text, None)
    if value is not None:
        return value
    return int(text) if text.isdigit() else None


def _amount(digits: str, suffix: str | None) -> Decimal | None:
    try:
        value = Decimal(digits.replace(",", ""))
    except InvalidOperation:
        return None
    if suffix == "k":
        value *= 1000
    return value if value > 0 else None


def _clock(hour: str, minute: str | None, meridiem: str) -> time | None:
    h = int(hour)
    if not 1 <= h <= 12:
        return None
    return time(h % 12 + (12 if meridiem == "pm" else 0), int(minute or 0))


def _weekend_start(today: date) -> date:
    """The Saturday of this weekend (today, on a Saturday or Sunday)."""
    return today if today.weekday() >= 5 else today + timedelta(days=5 - today.weekday())


def parse_travel_date(text: str, today: date) -> date | None:
    """A single unambiguous date from the words, or None ("this month", "next Friday")."""
    text = text.lower()
    iso = _ISO.search(text)
    if iso:
        try:
            return date(int(iso.group(1)), int(iso.group(2)), int(iso.group(3)))
        except ValueError:
            return None
    for pattern, month_first in ((_MONTH_DAY, True), (_DAY_MONTH, False)):
        match = pattern.search(text)
        if match:
            month_word, day = (match.group(1), match.group(2)) if month_first else (
                match.group(2), match.group(1),
            )
            try:
                found = date(today.year, _MONTHS[month_word], int(day))
                return found if found >= today else date(today.year + 1, found.month, found.day)
            except ValueError:
                return None
    if re.search(r"\b(?:day after tomorrow|samakalawa)\b", text):
        return today + timedelta(days=2)
    if re.search(r"\b(?:tomorrow|bukas)\b", text):
        return today + timedelta(days=1)
    if re.search(r"\b(?:today|tonight|ngayon)\b", text):
        return today
    if "next weekend" in text:
        return _weekend_start(today) + timedelta(days=7) if today.weekday() < 6 else today + timedelta(days=6)
    if "this weekend" in text:
        return _weekend_start(today)
    in_days = _IN_DAYS.search(text)
    if in_days and _count(in_days.group(1)):
        return today + timedelta(days=_count(in_days.group(1)))
    weekday = _WEEKDAY.search(text)
    if weekday and not weekday.group(1):  # "next Friday" is ambiguous: ask for the date
        ahead = (_WEEKDAYS[weekday.group(2)] - today.weekday()) % 7
        return today + timedelta(days=ahead) if ahead else None
    return None


def interpret_short_answer(message: str, state: PlanningState, today: date) -> dict[str, Any]:
    """Plan details a short answer states, as {field: value}; empty when nothing is clear."""
    text = message.strip().lower().rstrip("?.! ").replace("’", "'")
    if not text:
        return {}
    pending = missing_details(state)
    asked = pending[0] if pending else None
    short = len(text.split()) <= 8
    is_question = message.strip().endswith("?")
    found: dict[str, Any] = {}

    # How long: only beside the day question; changing an existing length is the
    # model's call, so a phrase like "make it a day trip" is not read here.
    if asked == "day_count" and _DAY_TRIP.search(text):
        found.update(day_count=1, night_count=0)
    elif asked == "day_count":
        days = _DAYS_NIGHTS.search(text)
        if days and short:
            found["day_count"] = _count(days.group(1))
            if days.group(2):
                found["night_count"] = _count(days.group(2))

    # How many travelers.
    if _SOLO.match(text):
        found["traveler_count"] = 1
    elif _COUPLE.search(text) and (asked == "traveler_count" or short):
        found["traveler_count"] = 2
    elif asked == "traveler_count" and (party := _PARTY.match(text)):
        found["traveler_count"] = _count(party.group(1))
    elif (explicit := _PARTY_EXPLICIT.search(text)) and short and _CORRECTION.search(text):
        found["traveler_count"] = _count(explicit.group(1))

    # Budget: a bare amount beside the budget question, or one said with a money word.
    amount = None
    if asked == "total_budget" and (bare := _BARE_AMOUNT.match(text)):
        amount = _amount(bare.group(1), bare.group(2) if bare.group(2) == "k" else None)
    elif short and (spoken := _EXPLICIT_AMOUNT.search(text)):
        amount = _amount(spoken.group(1) or spoken.group(3), spoken.group(2) or spoken.group(4))
    elif state.total_budget is not None and short and _CORRECTION.search(text):
        any_amount = _AMOUNT_ANYWHERE.search(text)
        if any_amount and "day_count" not in found and "traveler_count" not in found:
            amount = _amount(any_amount.group(1), any_amount.group(2))
    if amount is not None:
        found["total_budget"] = amount

    # Answers to the Nature questions, only beside the question they answer.
    if asked == "activity_level" and short:
        levels = [
            level for level, pattern in (("challenging", _HARD), ("moderate", _MODERATE), ("easy", _EASY))
            if pattern.search(text)
        ]
        if len(levels) == 1:
            found["activity_level"] = levels[0]
    if asked == "prefers_quiet" and short:
        quiet, popular = bool(_QUIET.search(text)), bool(_POPULAR.search(text))
        if quiet != popular:
            found["prefers_quiet"] = quiet

    # Travel date: beside the date question, or said as a plan ("we leave tomorrow").
    if short and not is_question and (asked == "travel_start_date" or _TRAVEL_WORDS.search(text)):
        when = parse_travel_date(text, today)
        if when is not None:
            found["travel_start_date"] = when

    # Times of day, only when stated outright.
    if (back := _RETURN_BY.search(text)) and (deadline := _clock(*back.groups())):
        found["return_deadline"] = deadline
    if (leave := _DEPART_AT.search(text)) and (depart := _clock(*leave.groups())):
        found["departure_time"] = depart
    return found


_VAGUE_DATE = re.compile(
    r"\b(?:this|next|last)\s+(?:month|week|year)\b|\bnext\s+(?:"
    + "|".join(_WEEKDAYS) + r")\b|\b(?:soon|later|sometime|anytime|someday)\b"
)


def is_vague_date_answer(message: str, state: PlanningState, today: date) -> bool:
    """True when the travel date is the open question and the answer names no single day."""
    text = message.strip().lower().rstrip("?.! ")
    pending = missing_details(state)
    return (
        bool(pending) and pending[0] == "travel_start_date"
        and len(text.split()) <= 8 and not message.strip().endswith("?")
        and parse_travel_date(text, today) is None
        and bool(_VAGUE_DATE.search(text))
    )


def describe(found: dict[str, Any]) -> str:
    """Plain words for what was saved, for a reply the server writes itself."""
    parts: list[str] = []
    if "traveler_count" in found:
        n = found["traveler_count"]
        parts.append("1 traveler" if n == 1 else f"{n} travelers")
    if found.get("day_count") == 1 and found.get("night_count") == 0:
        parts.append("a day trip")
    elif "day_count" in found:
        days = found["day_count"]
        nights = found.get("night_count")
        parts.append(f"{days} day{'s' if days != 1 else ''}" + (
            f", {nights} night{'s' if nights != 1 else ''}" if nights is not None else ""))
    if "total_budget" in found:
        parts.append(f"a budget of ₱{found['total_budget']:,.0f}")
    if "activity_level" in found:
        parts.append(f"{found['activity_level']} activities")
    if "prefers_quiet" in found:
        parts.append("quiet places" if found["prefers_quiet"] else "popular places are fine")
    if "travel_start_date" in found:
        parts.append(f"travelling on {found['travel_start_date']:%B} {found['travel_start_date'].day}")
    if "departure_time" in found:
        parts.append(f"leaving at {found['departure_time']:%I:%M %p}".replace(" 0", " "))
    if "return_deadline" in found:
        parts.append(f"back by {found['return_deadline']:%I:%M %p}".replace(" 0", " "))
    return ", ".join(parts)

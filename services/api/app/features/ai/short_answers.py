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
_PARTY_EXPLICIT = re.compile(r"\b" + _NUMBER + r" (?:people|persons?|pax|travell?ers?)\b")
_ADULT_COUNT = re.compile(r"\b" + _NUMBER + r"\s+adults?\b")
_CHILD_COUNT = re.compile(r"\b" + _NUMBER + r"\s+(?:kids?|children|child)\b")
_CHILD_AGES_LIST = re.compile(
    r"\bages?\s*(?:are|is|:)?\s*((?:\d{1,2})(?:\s*(?:,|and|&)\s*\d{1,2})*)\b"
)
_CHILD_AGES_PARENS = re.compile(
    r"\b(?:kids?|children|child)\s*\(\s*(?:ages?\s*)?((?:\d{1,2})(?:\s*(?:,|and|&)\s*\d{1,2})*)\s*\)"
)
_CHILD_AGE_YEARS_OLD = re.compile(r"\b(\d{1,2})[- ]?(?:years?[- ]?old|yrs?[- ]?old|yo)\b")
_DAY_TRIP = re.compile(r"\b(?:day trip|one[- ]day|1[- ]day|same[- ]day)\b")
_DAYS_NIGHTS = re.compile(
    r"\b" + _NUMBER + r" days?(?:\s*(?:,|and|&)?\s*" + _NUMBER + r" nights?)?\b"
)
_NIGHTS_DAYS = re.compile(
    r"\b" + _NUMBER + r" nights?\s*(?:,|and|&)?\s*" + _NUMBER + r" days?\b"
)
_BARE_AMOUNT = re.compile(r"^(?:₱|php|p)?\s*([\d,]+(?:\.\d+)?)\s*(k|pesos?|php)?$")
_EXPLICIT_AMOUNT = re.compile(
    r"(?:budget\s*(?:is|of|at|around|about|:)?\s*(?:₱\s*|php\s*)?|₱\s?|php\s?)([\d,]+(?:\.\d+)?)\s*(k)?\b"
    r"(?!\s*(?:days?|nights?|people|persons?|pax|travell?ers?|adults?|kids?|children|child|years?))"
    r"|\b([\d,]+(?:\.\d+)?)\s*(k)?\s*(?:pesos?|php)\b"
)
_BUDGET_CLAUSE = re.compile(
    r"\bbudget\b[^.!?\n]{0,30}?\b(?:is|of|at|around|about)\s*(?:₱\s*|php\s*)?([\d,]+(?:\.\d+)?)\s*(k)?\b"
    r"(?!\s*(?:days?|nights?|people|persons?|pax|travell?ers?|adults?|kids?|children|child|years?|yo))"
)
_CORRECTION = re.compile(
    r"\b(?:make it|change (?:it |the budget |budget )?to|raise|increase|lower|reduce|"
    r"set (?:the )?budget (?:to|at)|instead|actually)\b"
)
_AMOUNT_ANYWHERE = re.compile(r"([\d,]+(?:\.\d+)?)\s*(k)?\b(?!\s*(?:days?|nights?|people|persons?|pax))")
_EASY = re.compile(r"\b(?:easy|relaxed|chill|light|slow|leisure|walking)\b")
_MODERATE = re.compile(r"\b(?:moderate|medium|average|trek|trekking)\b")
_HARD = re.compile(r"\b(?:challenging|hard|difficult|extreme|strenuous|intense)\b")
_QUALIFIED_EASY = re.compile(
    r"\b(?:easy|relaxed|chill|light)\s+(?:hikes?|trails?|walks?|treks?|activities|pace)\b"
    r"|\bactivity\s+level\s*(?:is|:|to)?\s*(?:easy|relaxed|chill|light)\b"
)
_QUALIFIED_MODERATE = re.compile(
    r"\b(?:moderate|medium)\s+(?:hikes?|trails?|walks?|treks?|activities|pace)\b"
    r"|\bactivity\s+level\s*(?:is|:|to)?\s*(?:moderate|medium)\b"
)
_QUALIFIED_HARD = re.compile(
    r"\b(?:challenging|hard|strenuous|intense)\s+(?:hikes?|trails?|walks?|treks?|activities|pace)\b"
    r"|\bactivity\s+level\s*(?:is|:|to)?\s*(?:challenging|hard|strenuous|intense)\b"
)
_QUIET = re.compile(r"\b(?:quiet|peaceful|calm|tahimik)\b")
_POPULAR = re.compile(r"\b(?:popular|busy|lively|crowded|fine|okay|ok)\b")
_QUALIFIED_QUIET = re.compile(
    r"\b(?:quiet|peaceful|calm)\s+(?:places?|spots?|beaches?|trails?|areas?|resorts?)\b"
    r"|\bprefer\s+(?:quiet|peaceful|calm)\b"
)
_QUALIFIED_POPULAR = re.compile(
    r"\b(?:popular|busy|lively|crowded)\s+(?:places?|spots?|beaches?|areas?)\s*"
    r"(?:are\s+(?:fine|okay|ok)|(?:is\s+)?(?:fine|okay|ok))?\b"
    r"|\bprefer\s+(?:popular|lively)\b"
)

_ISO = re.compile(r"\b(\d{4})-(\d{2})-(\d{2})\b")
_MONTH_DAY = re.compile(
    r"\b(jan|feb|mar|apr|may|jun|jul|aug|sept|sep|oct|nov|dec)[a-z]*\.? "
    r"(\d{1,2})(?:st|nd|rd|th)?(?:,?\s*(\d{4}))?\b"
)
_DAY_MONTH = re.compile(
    r"\b(\d{1,2})(?:st|nd|rd|th)? (?:of )?"
    r"(jan|feb|mar|apr|may|jun|jul|aug|sept|sep|oct|nov|dec)[a-z]*(?:,?\s*(\d{4}))?\b"
)
_WEEKDAY = re.compile(
    r"\b(next )?(?:this coming |coming |this |on )?(monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"
)
_IN_DAYS = re.compile(r"\bin " + _NUMBER + r" days?\b")
_TRAVEL_WORDS = re.compile(
    r"\b(?:travel|travelling|traveling|going|leave|leaving|depart|departing|trip|"
    r"start|starting|set off|start(?:ing)?\s+date|travel\s+date|date\s+is)\b"
    r"|\bon\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sept|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}\b"
    r"|\bon\s+\d{4}-\d{2}-\d{2}\b"
)
_CLOCK = (
    r"(?:(\d{1,2})(?::([0-5]\d))?\s?(am|pm)\b"
    r"|\b([01]?\d|2[0-3]):([0-5]\d)\b(?!\s?(?:am|pm)))"
)
_RETURN_BY = re.compile(
    r"\b(?:back|return(?:ing)?|home|be back|return deadline)\b"
    r"(?:(?!\b(?:leave|leaving|depart(?:ing)?|departure)\b).){0,18}?"
    r"(?:\b(?:by|before|at|around)\s+|@\s*)?" + _CLOCK
)
_RETURN_TRAILING = re.compile(_CLOCK + r"\s*(?:return(?:\s+deadline)?)\b")
_DEPART_AT = re.compile(
    r"\b(?:leave|leaving|depart(?:ing)?|departure|start(?:ing)?|set off)\b"
    r"(?:(?!\b(?:return(?:ing)?|back|home)\b).){0,18}?"
    r"(?:\b(?:at|around|by)\s+|@\s*)?" + _CLOCK
)
_DEPART_TRAILING = re.compile(_CLOCK + r"\s*(?:departure|depart|leave)\b")
_MAKE_IT_CLOCK = re.compile(
    r"^(?:make it|set(?: it)? to|change(?: it)? to)\s+" + _CLOCK + r"$"
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


def _clock(
    hour12: str | None,
    minute12: str | None,
    meridiem: str | None,
    hour24: str | None = None,
    minute24: str | None = None,
) -> time | None:
    if meridiem is not None and hour12 is not None:
        h = int(hour12)
        m = int(minute12 or 0)
        if not 1 <= h <= 12 or not 0 <= m <= 59:
            return None
        return time(h % 12 + (12 if meridiem == "pm" else 0), m)
    if hour24 is not None and minute24 is not None:
        h = int(hour24)
        m = int(minute24)
        if not 0 <= h <= 23 or not 0 <= m <= 59:
            return None
        return time(h, m)
    return None


def _weekend_start(today: date) -> date:
    """The Saturday of this weekend (today, on a Saturday or Sunday)."""
    return today if today.weekday() >= 5 else today + timedelta(days=5 - today.weekday())


def _parse_party_composition(text: str) -> dict[str, Any]:
    """Parse explicit adults + children (with optional child ages) without guessing."""
    adult_match = _ADULT_COUNT.search(text)
    if not adult_match:
        return {}
    adults = _count(adult_match.group(1))
    if adults is None or adults < 0 or adults > 100:
        return {}

    ages: list[int] = []
    if ages_match := _CHILD_AGES_LIST.search(text):
        ages = [int(n) for n in re.findall(r"\d{1,2}", ages_match.group(1))]
    elif parens_match := _CHILD_AGES_PARENS.search(text):
        ages = [int(n) for n in re.findall(r"\d{1,2}", parens_match.group(1))]
    else:
        ages = [int(n) for n in _CHILD_AGE_YEARS_OLD.findall(text)]

    if any(age < 0 or age > 17 for age in ages):
        return {}

    child_match = _CHILD_COUNT.search(text)
    stated_children = _count(child_match.group(1)) if child_match else None
    if ages:
        if stated_children is not None and stated_children != len(ages):
            return {}
        total = adults + len(ages)
        if total < 1 or total > 100:
            return {}
        return {
            "adult_count": adults,
            "child_ages": ages,
            "traveler_count": total,
        }

    if stated_children is not None:
        total = adults + stated_children
        if 1 <= total <= 100:
            return {"traveler_count": total}
        return {}

    if adults >= 1:
        return {"traveler_count": adults}
    return {}


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
            month_word, day, explicit_year = (
                (match.group(1), match.group(2), match.group(3))
                if month_first
                else (match.group(2), match.group(1), match.group(3))
            )
            try:
                month_num = _MONTHS[month_word]
                day_num = int(day)
                if explicit_year is not None:
                    return date(int(explicit_year), month_num, day_num)
                found = date(today.year, month_num, day_num)
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


def interpret_short_answer(
    message: str,
    state: PlanningState,
    today: date,
    *,
    last_assistant: str | None = None,
) -> dict[str, Any]:
    """Plan details a short or qualified answer states, as {field: value}; empty when unclear."""
    text = message.strip().lower().rstrip("?.! ").replace("’", "'")
    if not text:
        return {}
    pending = missing_details(state)
    asked = pending[0] if pending else None
    word_count = len(text.split())
    bare_short = word_count <= 8
    multi_clause = word_count <= 35
    is_question = message.strip().endswith("?")
    found: dict[str, Any] = {}

    # How long: beside the day question, or out-of-order explicit days/nights when unset.
    if asked == "day_count" and _DAY_TRIP.search(text):
        found.update(day_count=1, night_count=0)
    elif asked == "day_count" or (multi_clause and not is_question and state.day_count is None):
        if nights_days := _NIGHTS_DAYS.search(text):
            night_val = _count(nights_days.group(1))
            day_val = _count(nights_days.group(2))
            if day_val is not None:
                found["day_count"] = day_val
            if night_val is not None:
                found["night_count"] = night_val
        elif days := _DAYS_NIGHTS.search(text):
            if asked != "day_count" or bare_short or multi_clause:
                day_val = _count(days.group(1))
                if day_val is not None:
                    found["day_count"] = day_val
                if days.group(2):
                    night_val = _count(days.group(2))
                    if night_val is not None:
                        found["night_count"] = night_val

    # How many travelers (including explicit adults + child ages).
    if _SOLO.match(text):
        found["traveler_count"] = 1
    elif multi_clause and not is_question and (composition := _parse_party_composition(text)):
        found.update(composition)
    elif _COUPLE.search(text) and (asked == "traveler_count" or bare_short):
        found["traveler_count"] = 2
    elif asked == "traveler_count" and (party := _PARTY.match(text)):
        found["traveler_count"] = _count(party.group(1))
    elif (explicit := _PARTY_EXPLICIT.search(text)) and multi_clause and not is_question and (
        state.traveler_count is None or _CORRECTION.search(text)
    ):
        found["traveler_count"] = _count(explicit.group(1))

    # Budget: a bare amount beside the budget question, or one said with a money word.
    amount = None
    if asked == "total_budget" and (bare := _BARE_AMOUNT.match(text)):
        amount = _amount(bare.group(1), bare.group(2) if bare.group(2) == "k" else None)
    elif multi_clause and not is_question and (spoken := _EXPLICIT_AMOUNT.search(text)):
        amount = _amount(spoken.group(1) or spoken.group(3), spoken.group(2) or spoken.group(4))
    elif multi_clause and not is_question and (clause := _BUDGET_CLAUSE.search(text)):
        amount = _amount(clause.group(1), clause.group(2))
    elif state.total_budget is not None and bare_short and _CORRECTION.search(text):
        any_amount = _AMOUNT_ANYWHERE.search(text)
        if any_amount and "day_count" not in found and "traveler_count" not in found:
            amount = _amount(any_amount.group(1), any_amount.group(2))
    if amount is not None:
        found["total_budget"] = amount

    # Answers to the Nature questions: bare words only when asked; qualified phrases anytime.
    if asked == "activity_level" and bare_short:
        levels = [
            level for level, pattern in (("challenging", _HARD), ("moderate", _MODERATE), ("easy", _EASY))
            if pattern.search(text)
        ]
        if len(levels) == 1:
            found["activity_level"] = levels[0]
    elif multi_clause and not is_question:
        q_levels = [
            level for level, pattern in (
                ("challenging", _QUALIFIED_HARD),
                ("moderate", _QUALIFIED_MODERATE),
                ("easy", _QUALIFIED_EASY),
            )
            if pattern.search(text)
        ]
        if len(q_levels) == 1:
            found["activity_level"] = q_levels[0]

    if asked == "prefers_quiet" and bare_short:
        quiet, popular = bool(_QUIET.search(text)), bool(_POPULAR.search(text))
        if quiet != popular:
            found["prefers_quiet"] = quiet
    elif multi_clause and not is_question:
        q_quiet, q_popular = bool(_QUALIFIED_QUIET.search(text)), bool(_QUALIFIED_POPULAR.search(text))
        if q_quiet != q_popular:
            found["prefers_quiet"] = q_quiet

    # Travel date: beside the date question (bare_short), or qualified/explicit date anytime.
    if not is_question and (
        (bare_short and asked == "travel_start_date")
        or (multi_clause and (_TRAVEL_WORDS.search(text) or _ISO.search(text)))
    ):
        when = parse_travel_date(text, today)
        if when is not None:
            found["travel_start_date"] = when

    # Times of day: explicit phrases, or "Make it <clock>" when context disambiguates.
    back = _RETURN_BY.search(text) or _RETURN_TRAILING.search(text)
    if back and (deadline := _clock(*back.groups())):
        found["return_deadline"] = deadline
    leave = _DEPART_AT.search(text) or _DEPART_TRAILING.search(text)
    if leave and (depart := _clock(*leave.groups())):
        found["departure_time"] = depart
    if "departure_time" not in found and "return_deadline" not in found and not is_question:
        if (make_clock := _MAKE_IT_CLOCK.match(text)) and (parsed_t := _clock(*make_clock.groups())):
            la = (last_assistant or "").lower()
            asks_depart = bool(re.search(r"\b(?:depart(?:ure)?|leave|leaving|start(?:ing)?)\b", la))
            asks_return = bool(re.search(r"\b(?:return|back|deadline)\b", la))
            if asks_depart and not asks_return:
                found["departure_time"] = parsed_t
            elif asks_return and not asks_depart:
                found["return_deadline"] = parsed_t
            elif state.departure_time is not None and state.return_deadline is None:
                found["departure_time"] = parsed_t
            elif state.return_deadline is not None and state.departure_time is None:
                found["return_deadline"] = parsed_t
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
    if "adult_count" in found and "child_ages" in found:
        adults = found["adult_count"]
        ages = found["child_ages"]
        party = f"{adults} adult{'s' if adults != 1 else ''}"
        if ages:
            age_word = "age" if len(ages) == 1 else "ages"
            child_word = "child" if len(ages) == 1 else "children"
            party += f", {len(ages)} {child_word} ({age_word} {', '.join(str(a) for a in ages)})"
        parts.append(party)
    elif "traveler_count" in found:
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

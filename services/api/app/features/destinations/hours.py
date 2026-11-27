"""Reading structured opening hours: a one-line summary and "what applies on a date".

Times are local (Asia/Manila) wall-clock times. A place with no rows has unknown hours;
callers show "not listed", never "closed".
"""

import re
from collections.abc import Iterable
from datetime import date, time
from typing import Protocol

_DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")


class _Window(Protocol):
    weekday: int
    is_closed: bool
    opens_at: time | None
    closes_at: time | None


class _Exception(Protocol):
    starts_on: date
    ends_on: date
    is_closed: bool
    opens_at: time | None
    closes_at: time | None
    reason: str | None


def clock_text(value: time) -> str:
    """8:00 AM, 5:30 PM (no leading zero)."""
    return f"{value.hour % 12 or 12}:{value.minute:02d} {'AM' if value.hour < 12 else 'PM'}"


def _window_text(opens: time, closes: time) -> str:
    return f"{clock_text(opens)} to {clock_text(closes)}"


def _day_label(day: int, last: int) -> str:
    return _DAYS[day] if day == last else f"{_DAYS[day]} to {_DAYS[last]}"


def hours_summary(open_24_hours: bool | None, weekly: Iterable[_Window]) -> str | None:
    """"Mon to Fri 8:00 AM to 5:00 PM; Sat 8:00 AM to 12:00 PM; Sun closed", or None."""
    if open_24_hours:
        return "Open 24 hours"
    by_day: dict[int, list[str]] = {}
    for row in sorted(weekly, key=lambda r: (r.weekday, r.opens_at or time(0))):
        text = "closed" if row.is_closed else _window_text(row.opens_at, row.closes_at)
        by_day.setdefault(row.weekday, []).append(text)
    if not by_day:
        return None
    # Join consecutive days that share the same windows.
    parts: list[str] = []
    days = sorted(by_day)
    start = prev = days[0]
    for day in [*days[1:], None]:
        if day is not None and day == prev + 1 and by_day[day] == by_day[start]:
            prev = day
            continue
        parts.append(f"{_day_label(start, prev)} {' and '.join(by_day[start])}")
        if day is not None:
            start = prev = day
    return "; ".join(parts)


def hours_on(
    on: date,
    open_24_hours: bool | None,
    weekly: Iterable[_Window],
    exceptions: Iterable[_Exception] = (),
) -> tuple[str, list[tuple[time, time]]]:
    """What applies on a date: ("open_24_hours" | "closed" | "open" | "unknown", windows).

    A date-specific exception wins over the weekly schedule.
    """
    for exc in exceptions:
        if exc.starts_on <= on <= exc.ends_on:
            if exc.is_closed:
                return "closed", []
            return "open", [(exc.opens_at, exc.closes_at)]
    if open_24_hours:
        return "open_24_hours", []
    rows = [row for row in weekly if row.weekday == on.weekday()]
    if not rows:
        return "unknown", []
    if all(row.is_closed for row in rows):
        return "closed", []
    return "open", sorted((r.opens_at, r.closes_at) for r in rows if not r.is_closed)


_TIME_RANGE = re.compile(
    r"(?<![\d:])(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:-|–|—|to)\s*"
    r"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?(?![\d:])",
    re.IGNORECASE,
)
_NOT_ONE_WINDOW = re.compile(r"\b(?:off|closed|except|varies|vary|confirm|check|unknown|holiday)", re.IGNORECASE)


def _listed_clock(hour: str, minute: str | None, meridiem: str | None) -> time | None:
    h, m = int(hour), int(minute or 0)
    if m > 59:
        return None
    if meridiem:
        if not 1 <= h <= 12:
            return None
        return time(h % 12 + (12 if meridiem.lower() == "pm" else 0), m)
    return time(h, m) if h <= 23 else None


def listed_opening(text: str | None) -> time | None:
    """The opening time of hours written as free text, only when the text clearly gives
    one daily window ("10:00 AM - 5:00 PM", "Mo-Su 08:00-17:30").

    Anything else (several windows, "Su off", "varies", "confirm", a closing time before
    the opening time) gives None, so an unclear text is never read as a schedule. The
    result is a planning hint: text hours are not verified hours.
    """
    if not text or _NOT_ONE_WINDOW.search(text):
        return None
    found = list(_TIME_RANGE.finditer(text))
    if len(found) != 1:
        return None
    h1, m1, ap1, h2, m2, ap2 = found[0].groups()
    if bool(ap1) != bool(ap2):
        return None
    if not ap1 and not (m1 and m2):  # "5-10" could be a date range, not a time range
        return None
    opens, closes = _listed_clock(h1, m1, ap1), _listed_clock(h2, m2, ap2)
    if opens is None or closes is None or closes <= opens:
        return None
    return opens

"""Reading structured opening hours: a one-line summary and "what applies on a date".

Times are local (Asia/Manila) wall-clock times. A place with no rows has unknown hours;
callers show "not listed", never "closed".
"""

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

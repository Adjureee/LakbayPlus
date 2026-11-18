"""Reading a structured activity as one plain-language line.

Only what is recorded appears. A missing field is left out, never filled in, so the
line cannot claim availability, a price or a duration that nobody entered.
"""

from datetime import time
from decimal import Decimal
from typing import Protocol

from app.features.destinations.hours import clock_text
from app.features.destinations.prices import money_text

_AVAILABILITY = {
    "always": "available during opening hours",
    "scheduled": "runs on a schedule",
    "seasonal": "seasonal",
    "by_arrangement": "by arrangement",
}
_WEATHER = {
    "none": "not weather dependent",
    "dry_weather": "needs dry weather",
    "calm_seas": "needs calm seas",
    "daylight": "daylight only",
}
# Said when the availability was never entered, so the AI does not assume it.
UNCONFIRMED = "availability not confirmed"


class _Activity(Protocol):
    name: str
    description: str | None
    availability: str | None
    schedule_note: str | None
    last_admission_at: time | None
    duration_min_minutes: int | None
    duration_max_minutes: int | None
    extra_fee: Decimal | None
    fee_included_in_admission: bool | None
    effort_level: str | None
    accessibility_note: str | None
    min_age: int | None
    max_age: int | None
    restriction_note: str | None
    weather_dependency: str | None
    best_time_note: str | None
    best_time_basis: str | None


def _duration(low: int | None, high: int | None) -> str | None:
    if low is None and high is None:
        return None
    if low is not None and high is not None and low != high:
        return f"typically {low} to {high} minutes"
    return f"typically {low if low is not None else high} minutes"


def _ages(low: int | None, high: int | None) -> str | None:
    if low is not None and high is not None:
        return f"ages {low} to {high}"
    if low is not None:
        return f"ages {low} and up"
    if high is not None:
        return f"up to age {high}"
    return None


def _fee(row: _Activity) -> str | None:
    if row.extra_fee is None:
        return None
    cost = "no extra fee" if row.extra_fee == 0 else f"extra fee {money_text(row.extra_fee)}"
    if row.fee_included_in_admission is True:
        return f"{cost} (included in admission)"
    if row.fee_included_in_admission is False:
        return f"{cost} (not included in admission)"
    return cost


def activity_summary(row: _Activity) -> str:
    """"Zipline: challenging; typically 30 to 45 minutes; extra fee ₱500; ages 7 and up"."""
    parts = [
        row.effort_level,
        _AVAILABILITY.get(row.availability) if row.availability else UNCONFIRMED,
        row.schedule_note,
        f"last admission {clock_text(row.last_admission_at)}" if row.last_admission_at else None,
        _duration(row.duration_min_minutes, row.duration_max_minutes),
        _fee(row),
        _ages(row.min_age, row.max_age),
        row.restriction_note,
        _WEATHER.get(row.weather_dependency) if row.weather_dependency else None,
        row.accessibility_note,
        (
            f"best time: {row.best_time_note}"
            + (f" ({row.best_time_basis})" if row.best_time_basis else "")
            if row.best_time_note else None
        ),
    ]
    return f"{row.name}: " + "; ".join(p for p in parts if p)

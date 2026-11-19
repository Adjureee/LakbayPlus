"""Reading structured prices as a one-line summary.

No rows means the prices are unknown; callers show "not listed", never "free".
"""

from collections.abc import Iterable
from decimal import Decimal
from typing import Protocol

_ITEMS = ("entrance", "overnight", "parking", "cottage", "other")
_ITEM_LABELS = {
    "entrance": "Entrance", "overnight": "Overnight", "parking": "Parking",
    "cottage": "Cottage", "other": "Other fee",
}
_AUDIENCE_LABELS = {
    "adult": "adult", "child": "child", "senior": "senior", "pwd": "PWD",
    "student": "student", "resident": "resident", "non_resident": "non-resident",
    "everyone": "everyone",
}
_UNIT_LABELS = {
    "per_person": "per person", "per_group": "per group",
    "per_vehicle": "per vehicle", "per_night": "per night",
}


class _Price(Protocol):
    item: str
    audience: str
    amount: Decimal
    unit: str
    age_min: int | None
    age_max: int | None


def money_text(amount: Decimal) -> str:
    """₱100 or ₱100.50 (no trailing .00)."""
    value = Decimal(amount).quantize(Decimal("0.01"))
    return f"\u20b1{value:,.0f}" if value == value.to_integral() else f"\u20b1{value:,.2f}"


def _ages(row: _Price) -> str:
    if row.age_min is not None and row.age_max is not None:
        return f" (ages {row.age_min} to {row.age_max})"
    if row.age_min is not None:
        return f" (ages {row.age_min} and up)"
    if row.age_max is not None:
        return f" (up to age {row.age_max})"
    return ""


def prices_summary(prices: Iterable[_Price]) -> str | None:
    """"Entrance: adult ₱100 per person, child (ages 4 to 12) ₱50 per person; ...", or None."""
    by_item: dict[str, list[str]] = {}
    for row in prices:
        cost = "free" if row.amount == 0 else f"{money_text(row.amount)} {_UNIT_LABELS[row.unit]}"
        by_item.setdefault(row.item, []).append(
            f"{_AUDIENCE_LABELS[row.audience]}{_ages(row)} {cost}"
        )
    if not by_item:
        return None
    return "; ".join(
        f"{_ITEM_LABELS[item]}: {', '.join(by_item[item])}"
        for item in _ITEMS if item in by_item
    )

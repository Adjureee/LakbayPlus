"""How far to trust a group of facts about a place (hours, fees, ...)."""

from datetime import datetime, timedelta, timezone

# Facts checked longer ago than this are reported as estimated (design doc, decision 3).
STALE_AFTER = timedelta(days=365)


def data_quality(
    has_structured_hours: bool, has_text_hours: bool, verified_at: datetime | None,
    *, now: datetime | None = None,
) -> str:
    """supported (structured and recently verified), estimated, or unknown."""
    if not has_structured_hours and not has_text_hours:
        return "unknown"
    if has_structured_hours and verified_at is not None:
        current = now or datetime.now(timezone.utc)
        aware = verified_at if verified_at.tzinfo else verified_at.replace(tzinfo=timezone.utc)
        if current - aware <= STALE_AFTER:
            return "supported"
    return "estimated"

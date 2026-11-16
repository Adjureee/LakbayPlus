"""Review preference groups against the live catalog (read-only).

Run: python -m scripts.review_preference_groups

Prints, for every preference group and sub-type, the places it matches, the
places in no group, and a data-readiness table for the Nature attractions places
(which fields the scoring needs are missing or cannot be read). Use it to decide
which places need a correction in data/preference_groups.json
(include_destination_ids / exclude_destination_ids) or a data fix in the admin
app. It changes nothing.
"""

import asyncio

from sqlalchemy import select

from app.db.base import import_model_modules
from app.db.session import get_sessionmaker
from app.features.destinations.models import Destination
from app.features.recommendations import scoring
from app.features.recommendations.preference_groups import load_groups

# The fields the nature criteria read. (field, readable?) -> readable when the
# normalizer understands the stored text.
READINESS_FIELDS = (
    ("difficulty_level", lambda v: scoring.normalize_difficulty(v) is not None),
    ("crowd_level", lambda v: scoring.normalize_crowd(v) is not None),
    ("best_time_to_visit", lambda v: bool(str(v).strip())),
    ("estimated_cost", lambda v: True),
    ("is_kid_friendly", lambda v: v is True),
    ("is_elderly_friendly", lambda v: v is True),
)


async def main() -> None:
    import_model_modules()
    groups = load_groups()
    async with get_sessionmaker()() as session:
        places = (
            await session.execute(
                select(Destination).where(Destination.is_active.is_(True)).order_by(Destination.name)
            )
        ).scalars().all()

    print(f"{len(places)} active places\n")
    in_any_group: set[int] = set()
    for group in groups.groups.values():
        members = [
            (place, membership)
            for place in places
            if (membership := groups.membership(group.key, place.category, place.destination_id))
        ]
        in_any_group.update(place.destination_id for place, _ in members)
        print(f"== {group.label} ({len(members)})")
        if group.subtypes:
            for subtype in group.subtypes.values():
                names = [p.name for p, m in members if subtype.key in m.subtypes]
                print(f"   {subtype.label} ({len(names)}): {', '.join(names) or '-'}")
            loose = [p.name for p, m in members if not m.subtypes]
            if loose:
                print(f"   (added by id, no sub-type): {', '.join(loose)}")
        else:
            print("   " + (", ".join(p.name for p, _ in members) or "-"))
        print()

    outside = [p for p in places if p.destination_id not in in_any_group]
    print(f"== In no group ({len(outside)}) - check none of these is really nature:")
    for place in outside:
        print(f"   #{place.destination_id:<3} {place.name} ({place.category})")

    nature = [
        p for p in places if groups.membership("nature_attractions", p.category, p.destination_id)
    ]
    print(f"\n== Nature data readiness ({len(nature)} places)")
    header = "   " + "place".ljust(38) + "".join(name[:11].ljust(13) for name, _ in READINESS_FIELDS)
    print(header)
    gaps = 0
    for place in nature:
        cells = []
        for name, readable in READINESS_FIELDS:
            value = getattr(place, name)
            if value in (None, "", False):
                cells.append("missing")
                gaps += 1
            elif not readable(value):
                cells.append(f"? {str(value)[:9]}")
                gaps += 1
            else:
                cells.append("ok")
        print("   " + place.name[:36].ljust(38) + "".join(c.ljust(13) for c in cells))
    total = len(nature) * len(READINESS_FIELDS)
    print(f"\n   {total - gaps} of {total} values usable; {gaps} missing or unreadable.")


if __name__ == "__main__":
    asyncio.run(main())

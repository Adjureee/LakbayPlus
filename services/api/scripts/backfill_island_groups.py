"""Tag destinations and candidates on islands from OSM island outlines.

An island destination with no island_group would be routed by road across the
water; with it, routes go through a pier (see app.features.sea_links).

Preview: python -m scripts.backfill_island_groups
Apply:   python -m scripts.backfill_island_groups --apply

Only rows whose island_group is empty are changed, so admin corrections stay.
Rows outside Region XI are listed for review; nothing is deleted.
"""

import argparse
import asyncio

from sqlalchemy import select

from app.db.base import import_model_modules
from app.db.session import get_sessionmaker
from app.features.destinations.models import Destination, DestinationCandidate
from app.features.destinations.region import island_group_for, region_status


async def backfill(apply: bool) -> None:
    import_model_modules()
    async with get_sessionmaker()() as session:
        for model, label in ((Destination, "destination"), (DestinationCandidate, "candidate")):
            rows = (await session.execute(select(model))).scalars().all()
            tagged = 0
            for row in rows:
                status = region_status(row.lat, row.lng)
                if status != "inside":
                    print(f"  review {label} {row.name!r}: {status} Region XI ({row.lat}, {row.lng})")
                if row.island_group:
                    continue
                group = island_group_for(row.lat, row.lng)
                if group is None:
                    continue
                print(f"  {label} {row.name!r} -> {group}")
                tagged += 1
                if apply:
                    row.island_group = group
            print(f"{label}s: {tagged} to tag of {len(rows)}")
        if apply:
            await session.commit()
            print("Applied.")
        else:
            print("Preview only. Use --apply to write.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Write island_group values")
    asyncio.run(backfill(parser.parse_args().apply))


if __name__ == "__main__":
    main()

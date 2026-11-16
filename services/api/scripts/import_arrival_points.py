"""Import reviewed gate/parking arrival points from the Davao dataset.

Preview: python -m scripts.import_arrival_points
Apply:   python -m scripts.import_arrival_points --apply

Only destinations listed in app/features/destinations/data/arrival_point_mapping.csv
are touched. See app.features.destinations.arrival_import for the rules. The
attraction pin (lat/lng) is never changed, and existing arrival points are
kept unless --overwrite is given.
"""

import argparse
import asyncio
from datetime import UTC, datetime
from pathlib import Path

from sqlalchemy import select

from app.db.base import import_model_modules
from app.db.session import get_sessionmaker
from app.features.destinations.arrival_import import (
    DEFAULT_DATASET,
    DEFAULT_MAPPING,
    DestinationPin,
    decide_arrival_updates,
    read_csv,
)
from app.features.destinations.models import Destination

ORDER = ("ready", "stored", "held", "skipped")


async def run(*, apply: bool, overwrite: bool, mapping: Path, dataset: Path) -> None:
    import_model_modules()
    async with get_sessionmaker()() as session:
        rows = (await session.execute(select(Destination))).scalars().all()
        by_id = {row.destination_id: row for row in rows}
        decisions = decide_arrival_updates(
            read_csv(mapping),
            read_csv(dataset),
            [
                DestinationPin(
                    destination_id=row.destination_id,
                    name=row.name,
                    lat=row.lat,
                    lng=row.lng,
                    has_arrival_point=row.arrival_lat is not None,
                )
                for row in rows
            ],
            overwrite=overwrite,
        )

        verified_at = datetime.now(UTC)
        for outcome in ORDER:
            group = [d for d in decisions if d.outcome == outcome]
            print(f"\n{outcome.upper()} ({len(group)})")
            for d in sorted(group, key=lambda item: item.destination_id):
                gap = f"{d.distance_meters:6.0f} m" if d.distance_meters is not None else "      -"
                print(f"  #{d.destination_id:<3} {d.destination_name[:34]:34} {gap}  {d.reason}")
                if not apply or outcome not in ("ready", "stored"):
                    continue
                row = by_id[d.destination_id]
                row.arrival_lat = d.arrival_lat
                row.arrival_lng = d.arrival_lng
                row.arrival_source_url = d.source_url
                row.arrival_verified_at = verified_at if d.source_url else None
                row.route_ready = outcome == "ready"

        unmapped = sorted(set(by_id) - {d.destination_id for d in decisions})
        print(f"\nNOT IN MAPPING ({len(unmapped)}): " + ", ".join(
            f"#{i} {by_id[i].name}" for i in unmapped
        ))

        if apply:
            await session.commit()
            print("\nApplied.")
        else:
            print("\nPreview only. Use --apply to write.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Write arrival points")
    parser.add_argument("--overwrite", action="store_true", help="Replace existing arrival points")
    parser.add_argument("--mapping", type=Path, default=DEFAULT_MAPPING)
    parser.add_argument("--dataset", type=Path, default=DEFAULT_DATASET)
    args = parser.parse_args()
    asyncio.run(run(
        apply=args.apply, overwrite=args.overwrite, mapping=args.mapping, dataset=args.dataset,
    ))


if __name__ == "__main__":
    main()

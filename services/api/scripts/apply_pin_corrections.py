"""Move destination pins to reviewed coordinates (and set arrival points).

Preview: python -m scripts.apply_pin_corrections
Apply:   python -m scripts.apply_pin_corrections --apply

Reads app/features/destinations/data/pin_corrections.csv. A row is applied only
while the destination still has the recorded old pin, so a pin someone already
changed is never overwritten. Undo by swapping old/new values in the file.
Rows with an arrival point also become route_ready (source_url is the evidence).
"""

import argparse
import asyncio
from datetime import UTC, datetime

from app.db.base import import_model_modules
from app.db.session import get_sessionmaker
from app.features.destinations.arrival_import import DATA_DIR, haversine_meters, read_csv
from app.features.destinations.models import Destination
from app.features.destinations.repository import DestinationRepository

CORRECTIONS = DATA_DIR / "pin_corrections.csv"
SAME_PIN_METERS = 5.0


def _optional(value: str) -> float | None:
    return float(value) if value.strip() else None


async def run(apply: bool) -> None:
    import_model_modules()
    async with get_sessionmaker()() as session:
        repo = DestinationRepository(session)
        now = datetime.now(UTC)
        for row in read_csv(CORRECTIONS):
            destination = await session.get(Destination, int(row["destination_id"]))
            label = f"#{row['destination_id']:<3} {row['name'][:30]:30}"
            if destination is None:
                print(f"  skip {label} not in database")
                continue
            old = (float(row["old_lat"]), float(row["old_lng"]))
            new = (float(row["new_lat"]), float(row["new_lng"]))
            current = (destination.lat, destination.lng)
            if haversine_meters(*current, *new) <= SAME_PIN_METERS:
                print(f"  done {label} already at the corrected pin")
                continue
            if haversine_meters(*current, *old) > SAME_PIN_METERS:
                print(f"  skip {label} pin changed since review: {current}")
                continue
            moved = haversine_meters(*old, *new)
            values: dict = {"lat": new[0], "lng": new[1]}
            arrival = (_optional(row["arrival_lat"]), _optional(row["arrival_lng"]))
            if arrival[0] is not None and arrival[1] is not None:
                values.update(
                    arrival_lat=arrival[0],
                    arrival_lng=arrival[1],
                    arrival_source_url=row["source_url"],
                    arrival_verified_at=now,
                    route_ready=True,
                )
            elif destination.arrival_lat is not None and haversine_meters(
                new[0], new[1], destination.arrival_lat, destination.arrival_lng,
            ) > 1500:
                # An arrival point chosen for the old pin no longer fits.
                values.update(
                    arrival_lat=None, arrival_lng=None, arrival_source_url=None,
                    arrival_verified_at=None, route_ready=False,
                )
            extra = " + arrival point" if "arrival_lat" in values and values["arrival_lat"] else ""
            print(f"  move {label} {moved / 1000:5.2f} km -> {new}{extra}")
            if apply:
                await repo.update(destination, values)
        if apply:
            await session.commit()
            print("Applied.")
        else:
            print("Preview only. Use --apply to write.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true", help="Write corrected pins")
    asyncio.run(run(parser.parse_args().apply))


if __name__ == "__main__":
    main()

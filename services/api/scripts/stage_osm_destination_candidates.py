"""Stage reviewed OSM visitor candidates without publishing them.

Preview: python -m scripts.stage_osm_destination_candidates
Apply after migration: python -m scripts.stage_osm_destination_candidates --apply
Options: --limit 120 (stage the highest-priority rows first), --skip-resorts

Each staged row is prefilled so admins only confirm and publish:
- district from the Region XI province outline (rows outside the region are skipped),
- island_group from OSM island outlines (so island places route through a pier),
- category from the triage suggestion, and starter vibes/activities for it.
Visitor purpose, description, fees and access stay for the admin to verify;
nothing is published by this script.
"""

import argparse
import asyncio
import json
from collections import Counter
from pathlib import Path

from sqlalchemy import select

from app.db.base import import_model_modules
from app.db.session import get_sessionmaker
from app.features.destinations.models import DestinationCandidate
from app.features.destinations.region import island_group_for, province_for, region_status


DEFAULT_INPUT = (
    Path(__file__).resolve().parents[1]
    / "docs/archive/davao_region_osm_catalog_triage_2026-11-04.jsonl"
)

# Starter vibes/activities per category, for the admin to adjust before publishing.
CATEGORY_PREFILL: dict[str, tuple[str, str]] = {
    "waterfall": ("nature, adventure, refreshing", "swimming, short hike, photography"),
    "beach": ("beach, relaxed, sunny", "swimming, sunbathing, photography"),
    "beach resort": ("beach, relaxed", "swimming, day tour, overnight stay"),
    "resort": ("relaxed, leisure", "swimming, day tour, overnight stay"),
    "park": ("relaxed, family-friendly", "walking, picnic, photography"),
    "garden": ("nature, relaxed", "garden walk, photography"),
    "viewpoint": ("scenic, photography", "sightseeing, photography"),
    "museum": ("culture, educational", "museum visit, learning"),
    "lighthouse": ("scenic, coastal", "sightseeing, photography"),
    "cave": ("adventure, nature", "guided caving, exploring"),
    "camping": ("outdoors, adventure", "camping, stargazing"),
    "wildlife": ("nature, educational, family-friendly", "wildlife viewing, photography"),
    "water park": ("family-friendly, fun", "swimming, water slides"),
    "nature reserve": ("nature, conservation", "hiking, birdwatching"),
    "attraction": ("sightseeing", "sightseeing, photography"),
}
# Scenic and public places first; private resorts last (they need access checks).
CATEGORY_PRIORITY = [
    "waterfall", "beach", "viewpoint", "nature reserve", "wildlife", "cave",
    "museum", "park", "garden", "lighthouse", "water park", "attraction",
    "camping", "beach resort", "resort",
]


def load_candidates(path: Path) -> list[dict]:
    candidates: dict[tuple[str, int], dict] = {}
    with path.open(encoding="utf-8") as source:
        for line_number, line in enumerate(source, start=1):
            row = json.loads(line)
            if row["review_decision"] != "visitor_candidate_review":
                continue
            identity = (row["osm_type"], int(row["osm_id"]))
            if identity not in candidates:
                if row["osm_type"] not in {"node", "way", "relation"}:
                    raise ValueError(f"Invalid OSM type on line {line_number}")
                if not (-90 <= row["latitude"] <= 90 and -180 <= row["longitude"] <= 180):
                    raise ValueError(f"Invalid coordinates on line {line_number}")
                if row["osm_url"] != f"https://www.openstreetmap.org/{identity[0]}/{identity[1]}":
                    raise ValueError(f"Invalid OSM URL on line {line_number}")
                candidates[identity] = row
    return list(candidates.values())


def prefill(row: dict) -> dict:
    """Reviewable field suggestions for one triage row."""
    lat, lng = row["latitude"], row["longitude"]
    category = (row.get("suggested_category") or "").strip().casefold() or None
    vibes, activities = CATEGORY_PREFILL.get(category or "", (None, None))
    island = island_group_for(lat, lng)
    return {
        "region_status": region_status(lat, lng),
        "district": province_for(lat, lng),
        "island_group": island,
        "category": category,
        "vibes": vibes,
        "activities": activities,
    }


def prioritized(rows: list[dict], *, skip_resorts: bool = False) -> list[dict]:
    rank = {name: index for index, name in enumerate(CATEGORY_PRIORITY)}

    def key(row: dict) -> tuple:
        category = (row.get("suggested_category") or "").casefold()
        return (rank.get(category, len(rank)), bool(row.get("exact_seed_name_match")), row["name"])

    chosen = [
        row for row in rows
        if not (skip_resorts and (row.get("suggested_category") or "").casefold() in {"resort", "beach resort"})
    ]
    return sorted(chosen, key=key)


def _review_notes(row: dict, fields: dict) -> str:
    notes = [
        "Prefilled by the staging script: confirm district, category, vibes and "
        "activities; write the visitor purpose; verify access before publishing."
    ]
    if fields["island_group"]:
        notes.append(
            f"On {fields['island_group']} island: confirm the pier/boat connection."
        )
    if fields["region_status"] == "near_boundary":
        notes.append("Near the Region XI boundary: confirm the place is in the Davao Region.")
    if row.get("same_osm_id_in_multiple_areas"):
        notes.append("OSM object appears in multiple area files; check the area.")
    if row.get("exact_seed_name_match"):
        notes.append("Possible existing catalog name match; check before publishing.")
    return " ".join(notes)


async def stage(
    path: Path, *, limit: int | None = None, skip_resorts: bool = False,
) -> tuple[int, int]:
    import_model_modules()
    rows = prioritized(load_candidates(path), skip_resorts=skip_resorts)
    async with get_sessionmaker()() as session:
        existing = await session.execute(
            select(DestinationCandidate.osm_type, DestinationCandidate.osm_id)
        )
        identities = set(existing.all())
        added = skipped = 0
        for row in rows:
            if limit is not None and added >= limit:
                break
            identity = (row["osm_type"], int(row["osm_id"]))
            fields = prefill(row)
            if identity in identities or fields["region_status"] == "outside":
                skipped += 1
                continue
            session.add(
                DestinationCandidate(
                    osm_type=identity[0],
                    osm_id=identity[1],
                    osm_url=row["osm_url"],
                    source_area=row["source_area"],
                    source_tag=row["source_tag"],
                    name=row["name"],
                    lat=row["latitude"],
                    lng=row["longitude"],
                    suggested_category=row["suggested_category"],
                    category=fields["category"],
                    district=fields["district"],
                    vibes=fields["vibes"],
                    activities=fields["activities"],
                    island_group=fields["island_group"],
                    operating_hours=row.get("osm_opening_hours") or None,
                    review_status="staged",
                    review_notes=_review_notes(row, fields),
                )
            )
            identities.add(identity)
            added += 1
        await session.commit()
        return added, skipped


def preview(path: Path, *, limit: int | None, skip_resorts: bool) -> None:
    rows = prioritized(load_candidates(path), skip_resorts=skip_resorts)
    fields = [(row, prefill(row)) for row in rows]
    eligible = [(row, item) for row, item in fields if item["region_status"] != "outside"]
    chosen = eligible[:limit] if limit else eligible
    print(f"Preview: {len(rows)} unique candidates, {len(rows) - len(eligible)} outside Region XI.")
    print(f"Would stage up to {len(chosen)} (existing OSM identities are skipped on --apply).")
    print("By district:", dict(Counter(item["district"] or "near boundary" for _, item in chosen)))
    print("By category:", dict(Counter(item["category"] for _, item in chosen).most_common()))
    print("On islands:", dict(Counter(item["island_group"] for _, item in chosen if item["island_group"])))
    outside = [row["name"] for row, item in fields if item["region_status"] == "outside"]
    if outside:
        print("Skipped outside Region XI:", ", ".join(outside[:20]))
    print("No database changes made. Use --apply to stage.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, default=DEFAULT_INPUT)
    parser.add_argument("--apply", action="store_true", help="Write staged rows to the configured database")
    parser.add_argument("--limit", type=int, default=None, help="Stage at most this many new rows")
    parser.add_argument("--skip-resorts", action="store_true", help="Leave private resorts out")
    args = parser.parse_args()
    if not args.apply:
        preview(args.input, limit=args.limit, skip_resorts=args.skip_resorts)
        return
    added, skipped = asyncio.run(
        stage(args.input, limit=args.limit, skip_resorts=args.skip_resorts)
    )
    print(f"Staged {added} candidates; skipped {skipped} already present or outside Region XI.")


if __name__ == "__main__":
    main()

"""Export published Region XI destinations into single-place app CSV data.

Reads active destinations from the backend PostgreSQL database (via
``DATABASE_URL`` or ``services/api/.env``) or via an optional HTTP backend
URL (``--api-url``) and generates ``apps/traveler_app/assets/data/places.csv``
with one destination per row and no fixed day count.

Usage:
    python scripts/export_app_places.py
    python scripts/export_app_places.py --api-url https://lakbay-api.example.com
"""

from __future__ import annotations

import argparse
import asyncio
import csv
import os
import re
from pathlib import Path
from typing import Any

import httpx

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = REPO_ROOT / "apps" / "traveler_app" / "assets" / "data" / "places.csv"
DEFAULT_ENV = REPO_ROOT / "services" / "api" / ".env"

CSV_COLUMNS = (
    "id",
    "name",
    "district",
    "category",
    "lat",
    "lng",
    "island_group",
    "stay_duration_type",
    "thumbnail",
)

VALID_STAY_TYPES = {"short", "half_day", "full_day", "overnight", "multi_day"}


def normalize_stay_duration(
    raw: str | None,
    *,
    category: str = "",
    overnight_fee: str | None = None,
) -> str:
    """Normalizes varied DB stay labels to canonical planner duration keys."""
    text = (raw or "").strip().lower().replace("-", "_").replace(" ", "_")
    if text in VALID_STAY_TYPES:
        return text
    if "short" in text or "1_2_hour" in text or "1-2_hour" in (raw or "").lower():
        return "short"
    if "half" in text:
        return "half_day"
    if "full" in text:
        return "full_day"
    if "multi" in text:
        return "multi_day"
    if "overnight" in text:
        return "overnight"
    if overnight_fee and str(overnight_fee).strip():
        return "overnight"

    cat = category.lower()
    if any(k in cat for k in ("museum", "church", "park", "plaza", "landmark", "viewpoint", "hot spring")):
        return "short"
    if any(k in cat for k in ("beach resort", "mountain resort", "waterfall", "cape")):
        return "full_day"
    if "island" in cat:
        return "multi_day"
    return "half_day"


def format_district(
    district: str | None,
    location: str | None,
    island_group: str | None = None,
) -> str:
    """Combines municipality/barangay location and province cleanly for Explore cards."""
    prov = (district or "").strip() or "Region XI"
    loc = (location or "").strip()
    if not loc:
        return prov

    cleaned = re.sub(r",?\s*Philippines\s*$", "", loc, flags=re.IGNORECASE).strip()
    cleaned = re.sub(r"^National Highway,\s*", "", cleaned, flags=re.IGNORECASE).strip()
    if cleaned.lower() in {"igacos", "island garden city of samal"} or island_group in {
        "samal",
        "talikud",
    }:
        if "samal" not in cleaned.lower():
            return f"Samal (IGaCoS), {prov}"
        if prov.lower() not in cleaned.lower():
            return f"Samal (IGaCoS), {prov}"

    if prov.lower() in cleaned.lower():
        # Trim very long street prefixes if concise segment + province suffices
        parts = [p.strip() for p in cleaned.split(",") if p.strip()]
        if len(parts) > 2:
            return ", ".join(parts[-2:])
        return cleaned
    parts = [p.strip() for p in cleaned.split(",") if p.strip()]
    municipality = parts[-1] if parts else cleaned
    return f"{municipality}, {prov}"


def normalize_category(raw: str | None) -> str:
    """Formats raw category tags into concise single-place card labels."""
    text = (raw or "").strip()
    if not text:
        return "Destination"
    if "/" in text:
        text = text.split("/", 1)[0].strip()
    return " ".join(w.capitalize() for w in text.split())


def _normalize_dsn(raw_url: str) -> str:
    return raw_url.replace("postgresql+asyncpg://", "postgresql://").replace(
        "postgresql+psycopg://", "postgresql://"
    )


async def fetch_from_database(database_url: str) -> list[dict[str, Any]]:
    """Loads all active published destinations directly from PostgreSQL."""
    import asyncpg

    conn = await asyncpg.connect(_normalize_dsn(database_url))
    try:
        rows = await conn.fetch(
            """
            SELECT destination_id, name, district, location, category,
                   lat, lng, island_group, stay_duration_type,
                   image_url, overnight_fee
            FROM destinations
            WHERE is_active = true
            ORDER BY destination_id
            """
        )
        return [dict(r) for r in rows]
    finally:
        await conn.close()


async def fetch_from_api(api_url: str) -> list[dict[str, Any]]:
    """Loads all active destinations from the backend REST catalog API."""
    base = api_url.rstrip("/")
    if not base.endswith("/api/v1"):
        base = f"{base}/api/v1"

    collected: list[dict[str, Any]] = []
    seen: set[int] = set()
    page_size = 100
    async with httpx.AsyncClient(timeout=20.0) as client:
        for offset in range(0, 1000, page_size):
            resp = await client.get(
                f"{base}/destinations",
                params={"limit": page_size, "offset": offset},
            )
            resp.raise_for_status()
            payload = resp.json()
            rows = payload if isinstance(payload, list) else payload.get("items", [])
            if not rows:
                break
            for item in rows:
                dest_id = int(item.get("destination_id") or item.get("id"))
                if dest_id in seen:
                    continue
                seen.add(dest_id)
                collected.append(item)
            if len(rows) < page_size:
                break
    return sorted(collected, key=lambda r: int(r.get("destination_id") or r.get("id")))


def to_place_row(raw: dict[str, Any]) -> dict[str, str]:
    """Maps a destination record to the single-place CSV schema (no days column)."""
    dest_id = int(raw.get("destination_id") or raw.get("id"))
    category = normalize_category(raw.get("category"))
    island_group = (raw.get("island_group") or "").strip().lower()
    stay_duration = normalize_stay_duration(
        raw.get("stay_duration_type"),
        category=category,
        overnight_fee=raw.get("overnight_fee"),
    )
    lat = float(raw["lat"])
    lng = float(raw["lng"])
    return {
        "id": f"api_{dest_id}",
        "name": str(raw["name"]).strip(),
        "district": format_district(
            raw.get("district"),
            raw.get("location"),
            island_group or None,
        ),
        "category": category,
        "lat": f"{lat:.6f}",
        "lng": f"{lng:.6f}",
        "island_group": island_group,
        "stay_duration_type": stay_duration,
        "thumbnail": str(raw.get("image_url") or "").strip(),
    }


def write_places_csv(rows: list[dict[str, Any]], output_path: Path) -> int:
    """Writes single-place CSV rows to disk and returns the exported count."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    formatted = [to_place_row(r) for r in rows]
    with output_path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(CSV_COLUMNS))
        writer.writeheader()
        writer.writerows(formatted)
    return len(formatted)


def _load_database_url(explicit: str | None) -> str | None:
    if explicit:
        return explicit
    if os.environ.get("DATABASE_URL"):
        return os.environ["DATABASE_URL"]
    if DEFAULT_ENV.is_file():
        for line in DEFAULT_ENV.read_text(encoding="utf-8").splitlines():
            stripped = line.strip()
            if not stripped or stripped.startswith("#") or "=" not in stripped:
                continue
            key, val = stripped.split("=", 1)
            if key.strip() == "DATABASE_URL":
                return val.strip().strip('"').strip("'")
    return None


async def async_main(args: argparse.Namespace) -> None:
    if args.api_url:
        rows = await fetch_from_api(args.api_url)
    else:
        db_url = _load_database_url(args.database_url)
        if not db_url:
            raise RuntimeError(
                "No DATABASE_URL found and no --api-url passed."
            )
        rows = await fetch_from_database(db_url)

    if not rows:
        raise RuntimeError("No active destinations returned; aborting CSV export.")

    count = write_places_csv(rows, Path(args.output))
    print(f"Exported {count} single places -> {args.output}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output",
        default=str(DEFAULT_OUT),
        help="Destination CSV output path",
    )
    parser.add_argument(
        "--database-url",
        default=None,
        help="Optional explicit PostgreSQL URL (defaults to DATABASE_URL / services/api/.env)",
    )
    parser.add_argument(
        "--api-url",
        default=None,
        help="Optional backend base URL to pull /api/v1/destinations instead of Postgres",
    )
    asyncio.run(async_main(parser.parse_args()))


if __name__ == "__main__":
    main()

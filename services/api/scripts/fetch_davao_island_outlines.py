"""Fetch Davao Region island outlines from OpenStreetMap for island detection.

Routing needs to know whether a stop is on an island (Samal, Talikud, Kopiat,
...) so it can route through a pier instead of across the water. This script
downloads named place=island/islet outlines inside Region XI from Overpass,
joins multipolygon coastline ways into closed rings, simplifies them, and
writes app/features/sea_links/data/island_outlines.json.

Data (c) OpenStreetMap contributors, ODbL 1.0 (https://www.openstreetmap.org/copyright).

Run: python -m scripts.fetch_davao_island_outlines
"""

import argparse
import json
import re
import time
from datetime import date
from pathlib import Path

import httpx

OUTPUT = (
    Path(__file__).resolve().parents[1]
    / "app/features/sea_links/data/island_outlines.json"
)
MIRRORS = (
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
)
HEADERS = {"User-Agent": "Lakbay-island-outlines/1.0"}
BBOX = (5.2, 124.95, 8.15, 126.85)
# Not Davao Region islands: the main island, and Indonesian islets in the bbox.
EXCLUDE_NAMES = {"Mindanao", "Pulau Miangas", "Pulau Baronto"}
# Lakbay island_group slugs used by destinations and sea_ports.
GROUP_NAMES = {"Samal": "samal", "Talicud": "talikud", "Balut Island": "balut"}
SIMPLIFY_METERS = 40.0


def overpass(query: str) -> dict:
    last_error: Exception | None = None
    for url in MIRRORS:
        for attempt in range(2):
            try:
                response = httpx.post(url, data={"data": query}, headers=HEADERS, timeout=120)
                if response.status_code == 200:
                    return response.json()
                last_error = RuntimeError(f"{url} HTTP {response.status_code}")
            except httpx.HTTPError as exc:
                last_error = exc
            time.sleep(2 * (attempt + 1))
    raise RuntimeError(f"All Overpass mirrors failed: {last_error}")


def slug(name: str) -> str:
    if name in GROUP_NAMES:
        return GROUP_NAMES[name]
    base = re.sub(r"\b(island|islet)\b", "", name, flags=re.IGNORECASE)
    return re.sub(r"[^a-z0-9]+", "_", base.casefold()).strip("_") or "island"


def join_ways(ways: list[list[tuple[float, float]]]) -> list[list[tuple[float, float]]]:
    """Join open way segments end-to-end into closed rings."""
    pending = [list(way) for way in ways if len(way) >= 2]
    rings = []
    while pending:
        ring = pending.pop(0)
        changed = True
        while ring[0] != ring[-1] and changed:
            changed = False
            for index, way in enumerate(pending):
                if way[0] == ring[-1]:
                    ring.extend(way[1:])
                elif way[-1] == ring[-1]:
                    ring.extend(reversed(way[:-1]))
                elif way[-1] == ring[0]:
                    ring[:0] = way[:-1]
                elif way[0] == ring[0]:
                    ring[:0] = list(reversed(way[1:]))
                else:
                    continue
                pending.pop(index)
                changed = True
                break
        if len(ring) >= 4 and ring[0] == ring[-1]:
            rings.append(ring)
    return rings


def simplify(points: list[tuple[float, float]], tolerance_m: float) -> list[tuple[float, float]]:
    """Douglas-Peucker on a local flat projection (meters)."""
    if len(points) < 4:
        return points
    lat0 = sum(p[0] for p in points) / len(points)
    import math
    kx = 111320.0 * math.cos(math.radians(lat0))
    ky = 110540.0

    def distance(p, a, b) -> float:
        px, py = p[1] * kx, p[0] * ky
        ax, ay = a[1] * kx, a[0] * ky
        bx, by = b[1] * kx, b[0] * ky
        dx, dy = bx - ax, by - ay
        if dx == dy == 0:
            return math.hypot(px - ax, py - ay)
        t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
        return math.hypot(px - (ax + t * dx), py - (ay + t * dy))

    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    while stack:
        start, end = stack.pop()
        best, index = 0.0, None
        for i in range(start + 1, end):
            d = distance(points[i], points[start], points[end])
            if d > best:
                best, index = d, i
        if index is not None and best > tolerance_m:
            keep[index] = True
            stack.extend([(start, index), (index, end)])
    simplified = [p for p, k in zip(points, keep) if k]
    return simplified if len(simplified) >= 4 else points


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    args = parser.parse_args()
    s, w, n, e = BBOX
    selector = '["place"~"^(island|islet)$"]["name"]'
    data = overpass(
        f"[out:json][timeout:90];(relation{selector}({s},{w},{n},{e});"
        f"way{selector}({s},{w},{n},{e}););out geom;"
    )
    islands = []
    for element in data.get("elements", []):
        name = (element.get("tags") or {}).get("name", "").strip()
        if not name or name in EXCLUDE_NAMES:
            continue
        if element["type"] == "way":
            ways = [[(p["lat"], p["lon"]) for p in element.get("geometry") or []]]
        else:
            ways = [
                [(p["lat"], p["lon"]) for p in member.get("geometry") or []]
                for member in element.get("members") or []
                if member.get("type") == "way" and member.get("role") in ("outer", "")
            ]
        rings = [simplify(ring, SIMPLIFY_METERS) for ring in join_ways(ways)]
        if not rings:
            print(f"  skipped {name}: no closed outline")
            continue
        islands.append({
            "island_group": slug(name),
            "name": name,
            "osm": f"https://www.openstreetmap.org/{element['type']}/{element['id']}",
            "rings": [[[round(lat, 6), round(lng, 6)] for lat, lng in ring] for ring in rings],
        })
    islands.sort(key=lambda item: item["name"])
    payload = {
        "source": "OpenStreetMap contributors, ODbL 1.0",
        "source_url": "https://www.openstreetmap.org/copyright",
        "fetched_on": date.today().isoformat(),
        "simplify_meters": SIMPLIFY_METERS,
        "islands": islands,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, separators=(",", ":")), encoding="utf-8")
    points = sum(len(ring) for item in islands for ring in item["rings"])
    print(f"Wrote {len(islands)} islands ({points} points) to {args.output}")
    for item in islands:
        print(f"  {item['island_group']:<20} {item['name']:<24} rings={len(item['rings'])}")


if __name__ == "__main__":
    main()

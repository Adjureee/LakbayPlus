"""Where a coordinate is: which Davao Region province, and which island.

- Provinces come from the simplified Region XI outlines also used by the admin
  map (data/davao_provinces_polygons.json, accurate to about a kilometer).
- Islands come from OpenStreetMap place=island/islet outlines
  (app/features/sea_links/data/island_outlines.json, from
  scripts/fetch_davao_island_outlines.py; (c) OpenStreetMap contributors, ODbL).

Lakbay uses these to keep the catalog inside Region XI and to tag island
destinations so routes cross by boat from a pier, never by road.
"""

import json
from functools import lru_cache
from pathlib import Path

_PROVINCES_PATH = Path(__file__).parent / "data" / "davao_provinces_polygons.json"
_ISLANDS_PATH = (
    Path(__file__).resolve().parents[1] / "sea_links" / "data" / "island_outlines.json"
)
# The province outlines are coarse; a place this close to Region XI's edge
# (but outside it) is reported as "near_boundary" for review, not rejected.
BOUNDARY_TOLERANCE_KM = 3.0

_Ring = list[tuple[float, float]]


def _bbox(ring: _Ring) -> tuple[float, float, float, float]:
    lats = [p[0] for p in ring]
    lngs = [p[1] for p in ring]
    return min(lats), min(lngs), max(lats), max(lngs)


def _in_ring(lat: float, lng: float, ring: _Ring) -> bool:
    inside = False
    count = len(ring)
    for i in range(count):
        a_lat, a_lng = ring[i]
        b_lat, b_lng = ring[(i + 1) % count]
        if (a_lat > lat) != (b_lat > lat):
            cross = a_lng + (lat - a_lat) * (b_lng - a_lng) / (b_lat - a_lat)
            if lng < cross:
                inside = not inside
    return inside


def _in_rings(lat: float, lng: float, rings: list[tuple[tuple, _Ring]]) -> bool:
    for (min_lat, min_lng, max_lat, max_lng), ring in rings:
        if min_lat <= lat <= max_lat and min_lng <= lng <= max_lng and _in_ring(lat, lng, ring):
            return True
    return False


@lru_cache(maxsize=1)
def _provinces() -> list[tuple[str, list[tuple[tuple, _Ring]]]]:
    raw = json.loads(_PROVINCES_PATH.read_text(encoding="utf-8"))
    return [
        (name, [(_bbox(ring), [tuple(p) for p in ring]) for ring in [
            [(float(p[0]), float(p[1])) for p in r] for r in rings
        ]])
        for name, rings in raw.items()
    ]


@lru_cache(maxsize=1)
def _islands() -> list[tuple[str, str, list[tuple[tuple, _Ring]]]]:
    if not _ISLANDS_PATH.exists():
        return []
    raw = json.loads(_ISLANDS_PATH.read_text(encoding="utf-8"))
    islands = []
    for item in raw.get("islands", []):
        rings = [[(float(p[0]), float(p[1])) for p in ring] for ring in item["rings"]]
        islands.append((item["island_group"], item["name"], [(_bbox(r), r) for r in rings]))
    return islands


def province_for(lat: float, lng: float) -> str | None:
    """Region XI province (or "Davao City") containing the point, else None."""
    for name, rings in _provinces():
        if _in_rings(lat, lng, rings):
            return name
    return None


def island_group_for(lat: float, lng: float) -> str | None:
    """Lakbay island_group slug ("samal", "talikud", ...) or None for mainland."""
    for group, _name, rings in _islands():
        if _in_rings(lat, lng, rings):
            return group
    return None


def region_status(lat: float, lng: float) -> str:
    """"inside", "near_boundary" (within the outline tolerance), or "outside"."""
    if province_for(lat, lng) is not None or island_group_for(lat, lng) is not None:
        return "inside"
    for _name, rings in _provinces():
        for _bounds, ring in rings:
            if _distance_to_ring_km(lat, lng, ring) <= BOUNDARY_TOLERANCE_KM:
                return "near_boundary"
    return "outside"


def _distance_to_ring_km(lat: float, lng: float, ring: _Ring) -> float:
    from math import cos, hypot, radians

    kx = 111.32 * cos(radians(lat))
    ky = 110.54
    best = float("inf")
    for i in range(len(ring)):
        a_lat, a_lng = ring[i]
        b_lat, b_lng = ring[(i + 1) % len(ring)]
        ax, ay = (a_lng - lng) * kx, (a_lat - lat) * ky
        bx, by = (b_lng - lng) * kx, (b_lat - lat) * ky
        dx, dy = bx - ax, by - ay
        length = dx * dx + dy * dy
        t = 0.0 if length == 0 else max(0.0, min(1.0, -(ax * dx + ay * dy) / length))
        best = min(best, hypot(ax + t * dx, ay + t * dy))
    return best


CANONICAL_PROVINCES: tuple[str, ...] = (
    "Davao City",
    "Davao del Norte",
    "Davao del Sur",
    "Davao Oriental",
    "Davao Occidental",
    "Davao de Oro",
)

_ISLAND_PROVINCE: dict[str, str] = {
    "samal": "Davao del Norte",
    "talikud": "Davao del Norte",
    "kopiat": "Davao de Oro",
    "balut": "Davao Occidental",
}

_PROVINCE_ALIASES: dict[str, str] = {
    "davao city": "Davao City",
    "toril": "Davao City",
    "marilog": "Davao City",
    "buda": "Davao City",
    "calinan": "Davao City",
    "mintal": "Davao City",
    "sasa": "Davao City",
    "davao del norte": "Davao del Norte",
    "del norte": "Davao del Norte",
    "samal": "Davao del Norte",
    "igacos": "Davao del Norte",
    "island garden city of samal": "Davao del Norte",
    "talikud": "Davao del Norte",
    "tagum": "Davao del Norte",
    "panabo": "Davao del Norte",
    "carmen": "Davao del Norte",
    "kapalong": "Davao del Norte",
    "davao de oro": "Davao de Oro",
    "de oro": "Davao de Oro",
    "compostela valley": "Davao de Oro",
    "comval": "Davao de Oro",
    "maragusan": "Davao de Oro",
    "nabunturan": "Davao de Oro",
    "maco": "Davao de Oro",
    "mabini": "Davao de Oro",
    "kopiat": "Davao de Oro",
    "new bataan": "Davao de Oro",
    "monkayo": "Davao de Oro",
    "pantukan": "Davao de Oro",
    "davao oriental": "Davao Oriental",
    "oriental": "Davao Oriental",
    "mati": "Davao Oriental",
    "dahican": "Davao Oriental",
    "cateel": "Davao Oriental",
    "aliwagwag": "Davao Oriental",
    "governor generoso": "Davao Oriental",
    "gov. generoso": "Davao Oriental",
    "gov generoso": "Davao Oriental",
    "san isidro": "Davao Oriental",
    "hamiguitan": "Davao Oriental",
    "baganga": "Davao Oriental",
    "lupon": "Davao Oriental",
    "pujada": "Davao Oriental",
    "davao del sur": "Davao del Sur",
    "del sur": "Davao del Sur",
    "digos": "Davao del Sur",
    "sta. cruz": "Davao del Sur",
    "sta cruz": "Davao del Sur",
    "santa cruz": "Davao del Sur",
    "bansalan": "Davao del Sur",
    "kapatagan": "Davao del Sur",
    "davao occidental": "Davao Occidental",
    "occidental": "Davao Occidental",
    "malita": "Davao Occidental",
    "balut": "Davao Occidental",
    "sarangani": "Davao Occidental",
}


def canonical_province_name(raw: str | None) -> str | None:
    """Resolve a province, city, or landmark label into a Region XI province name."""
    if not raw:
        return None
    normalized = " ".join(raw.lower().replace(",", " ").split())
    if normalized in _PROVINCE_ALIASES:
        return _PROVINCE_ALIASES[normalized]
    # Check longest aliases first so "davao del norte" beats shorter words.
    for alias in sorted(_PROVINCE_ALIASES, key=len, reverse=True):
        if alias in normalized:
            return _PROVINCE_ALIASES[alias]
    return None


def province_for_destination(
    lat: float,
    lng: float,
    *,
    district: str | None = None,
    location: str | None = None,
) -> str | None:
    """Return Region XI province using polygon lookup, island mapping, or boundary text."""
    province = province_for(lat, lng)
    if province is not None:
        return province
    island = island_group_for(lat, lng)
    if island is not None and island in _ISLAND_PROVINCE:
        return _ISLAND_PROVINCE[island]
    if region_status(lat, lng) != "outside":
        return canonical_province_name(district) or canonical_province_name(location)
    return None


@lru_cache(maxsize=1)
def _province_centroids() -> dict[str, tuple[float, float]]:
    centroids: dict[str, tuple[float, float]] = {}
    for name, rings in _provinces():
        points = [pt for _bbox_val, ring in rings for pt in ring]
        if points:
            centroids[name] = (
                sum(p[0] for p in points) / len(points),
                sum(p[1] for p in points) / len(points),
            )
    return centroids


def nearest_provinces(
    province: str | None = None,
    *,
    lat: float | None = None,
    lng: float | None = None,
    counts: dict[str, int] | None = None,
) -> list[str]:
    """Order Region XI provinces by match availability (if supplied) then proximity."""
    from math import cos, hypot, radians

    centroids = _province_centroids()
    if lat is not None and lng is not None:
        ref_lat, ref_lng = lat, lng
    elif province is not None and province in centroids:
        ref_lat, ref_lng = centroids[province]
    else:
        all_pts = list(centroids.values())
        ref_lat = sum(p[0] for p in all_pts) / len(all_pts)
        ref_lng = sum(p[1] for p in all_pts) / len(all_pts)

    kx = 111.32 * cos(radians(ref_lat))
    ky = 110.54
    candidates = [name for name in CANONICAL_PROVINCES if name != province and name in centroids]

    def sort_key(name: str) -> tuple[int, float, str]:
        c_lat, c_lng = centroids[name]
        dist_km = hypot((c_lng - ref_lng) * kx, (c_lat - ref_lat) * ky)
        has_matches = 0 if (counts is None or counts.get(name, 0) > 0) else 1
        return (has_matches, dist_km, name)

    return sorted(candidates, key=sort_key)

"""Decide which reviewed dataset arrival points may be written to destinations.

The dataset (``docs/davao_destinations_arrival_points_complete.csv``) gives a
gate, parking, trailhead or wharf point per place. It is paired with
destinations only through the hand-reviewed
``data/arrival_point_mapping.csv``: name matching paired wrong places in
testing (Malagos Garden with Montefrio, DDG Beach with Banana Beach).

Outcomes per mapped destination:

- ``ready``: arrival point stored and ``route_ready=True`` — routes end there.
- ``stored``: arrival point stored for reference, ``route_ready`` stays False
  (approximate point, wharf jump-off, or restricted access).
- ``held``: nothing written; the dataset point is too far from the current
  pin to be the same entrance. A person must check which one is right.
- ``skipped``: nothing written (already has an arrival point, bad row, ...).

The attraction pin (``lat``/``lng``, shown on the map) is never changed.
"""

from __future__ import annotations

import csv
from dataclasses import dataclass
from math import asin, cos, radians, sin, sqrt
from pathlib import Path
from typing import Literal

DATA_DIR = Path(__file__).resolve().parent / "data"
DEFAULT_MAPPING = DATA_DIR / "arrival_point_mapping.csv"
DEFAULT_DATASET = (
    Path(__file__).resolve().parents[3] / "docs" / "davao_destinations_arrival_points_complete.csv"
)

# A gate, parking area or trailhead farther than this from the attraction pin
# means one of the two coordinates is wrong.
MAX_PIN_TO_ARRIVAL_METERS = 1500.0
VERIFIED_PRECISIONS = frozenset({
    "verified_gate_frontage",
    "verified_highway_frontage",
    "verified_trailhead_parking",
})
# Never route_ready, even when the dataset says so.
BLOCKING_FAILURE_MODES = frozenset({"access_restriction", "multi_day_ferry_out_of_scope"})
# A wharf is where the boat leaves, not where an island destination is.
NON_ROAD_ARRIVAL_TYPES = frozenset({"jump_off_port_required", "restricted_or_conditional_access"})

Outcome = Literal["ready", "stored", "held", "skipped"]


@dataclass(frozen=True)
class DestinationPin:
    destination_id: int
    name: str
    lat: float
    lng: float
    has_arrival_point: bool = False


@dataclass(frozen=True)
class ArrivalDecision:
    destination_id: int
    destination_name: str
    dataset_row: str
    dataset_name: str
    outcome: Outcome
    reason: str
    distance_meters: float | None = None
    arrival_lat: float | None = None
    arrival_lng: float | None = None
    source_url: str | None = None


def read_csv(path: Path) -> list[dict[str, str]]:
    with path.open(encoding="utf-8", newline="") as handle:
        return list(csv.DictReader(handle))


def haversine_meters(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    p1, p2 = radians(lat1), radians(lat2)
    h = sin((p2 - p1) / 2) ** 2 + cos(p1) * cos(p2) * sin(radians(lng2 - lng1) / 2) ** 2
    return 2 * 6_371_000 * asin(sqrt(h))


def _is_true(value: str | None) -> bool:
    return (value or "").strip().lower() == "true"


def decide_arrival_updates(
    mapping: list[dict[str, str]],
    dataset: list[dict[str, str]],
    destinations: list[DestinationPin],
    *,
    overwrite: bool = False,
) -> list[ArrivalDecision]:
    rows = {row["original_row"].strip(): row for row in dataset}
    pins = {pin.destination_id: pin for pin in destinations}
    decisions: list[ArrivalDecision] = []
    seen: set[int] = set()

    for entry in mapping:
        destination_id = int(entry["destination_id"])
        dataset_row = entry["dataset_row"].strip()
        pin = pins.get(destination_id)
        row = rows.get(dataset_row)

        def decision(outcome: Outcome, reason: str, **extra) -> ArrivalDecision:
            return ArrivalDecision(
                destination_id=destination_id,
                destination_name=pin.name if pin else entry.get("destination_name", ""),
                dataset_row=dataset_row,
                dataset_name=row["name"] if row else entry.get("dataset_name", ""),
                outcome=outcome,
                reason=reason,
                **extra,
            )

        if destination_id in seen:
            decisions.append(decision("skipped", "destination mapped twice"))
            continue
        seen.add(destination_id)
        if pin is None:
            decisions.append(decision("skipped", "destination not in database"))
            continue
        if row is None:
            decisions.append(decision("skipped", "dataset row not found"))
            continue
        if pin.has_arrival_point and not overwrite:
            decisions.append(decision("skipped", "already has an arrival point"))
            continue
        try:
            lat, lng = float(row["latitude"]), float(row["longitude"])
        except (KeyError, ValueError):
            decisions.append(decision("skipped", "dataset coordinate is not a number"))
            continue
        if not (-90 <= lat <= 90 and -180 <= lng <= 180):
            decisions.append(decision("skipped", "dataset coordinate out of range"))
            continue

        distance = haversine_meters(pin.lat, pin.lng, lat, lng)
        point = {
            "distance_meters": distance,
            "arrival_lat": lat,
            "arrival_lng": lng,
            "source_url": (row.get("source_url") or "").strip() or None,
        }
        if distance > MAX_PIN_TO_ARRIVAL_METERS:
            decisions.append(decision(
                "held",
                f"dataset point is {distance / 1000:.2f} km from the current pin; "
                "check which is right",
                **point,
            ))
            continue

        blockers = []
        if not _is_true(row.get("route_ready")):
            blockers.append("dataset route_ready=False")
        if row.get("coordinate_precision", "").strip() not in VERIFIED_PRECISIONS:
            blockers.append(f"precision {row.get('coordinate_precision', '').strip() or '?'}")
        if row.get("snap_failure_mode", "").strip() in BLOCKING_FAILURE_MODES:
            blockers.append(f"failure mode {row['snap_failure_mode'].strip()}")
        if row.get("arrival_point_type", "").strip() in NON_ROAD_ARRIVAL_TYPES:
            blockers.append(f"arrival type {row['arrival_point_type'].strip()}")
        if not point["source_url"]:
            blockers.append("no source URL")

        if blockers:
            decisions.append(decision("stored", "; ".join(blockers), **point))
        else:
            decisions.append(decision("ready", "verified road-side arrival point", **point))
    return decisions

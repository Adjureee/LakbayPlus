from app.features.destinations.arrival_import import (
    DEFAULT_DATASET,
    DEFAULT_MAPPING,
    DestinationPin,
    decide_arrival_updates,
    read_csv,
)


def _row(**overrides):
    row = {
        "original_row": "10",
        "name": "Monfort Bat Sanctuary",
        "latitude": "7.1636",
        "longitude": "125.6948",
        "route_ready": "True",
        "coordinate_precision": "verified_gate_frontage",
        "snap_failure_mode": "none",
        "arrival_point_type": "road_gate_direct",
        "source_url": "https://example.org/monfort",
    }
    row.update(overrides)
    return row


MAPPING = [{"destination_id": "34", "dataset_row": "10"}]
PIN = DestinationPin(34, "Monfort Bat Sanctuary", 7.1655368, 125.6927417)


def test_verified_gate_near_pin_is_route_ready():
    [decision] = decide_arrival_updates(MAPPING, [_row()], [PIN])
    assert decision.outcome == "ready"
    assert decision.arrival_lat == 7.1636
    assert decision.distance_meters < 500


def test_far_dataset_point_is_held_not_written():
    [decision] = decide_arrival_updates(MAPPING, [_row(latitude="7.20")], [PIN])
    assert decision.outcome == "held"


def test_approximate_or_wharf_points_are_stored_but_not_route_ready():
    [approx] = decide_arrival_updates(
        MAPPING, [_row(coordinate_precision="approximate_barangay_corridor")], [PIN],
    )
    [wharf] = decide_arrival_updates(
        MAPPING, [_row(arrival_point_type="jump_off_port_required")], [PIN],
    )
    [restricted] = decide_arrival_updates(
        MAPPING, [_row(snap_failure_mode="access_restriction")], [PIN],
    )
    assert approx.outcome == wharf.outcome == restricted.outcome == "stored"


def test_existing_arrival_point_is_kept_unless_overwrite():
    pin = DestinationPin(34, "Monfort", 7.1655368, 125.6927417, has_arrival_point=True)
    [kept] = decide_arrival_updates(MAPPING, [_row()], [pin])
    [replaced] = decide_arrival_updates(MAPPING, [_row()], [pin], overwrite=True)
    assert kept.outcome == "skipped"
    assert replaced.outcome == "ready"


def test_mapping_file_pairs_existing_dataset_rows_once():
    mapping = read_csv(DEFAULT_MAPPING)
    dataset_rows = {row["original_row"] for row in read_csv(DEFAULT_DATASET)}
    ids = [entry["destination_id"] for entry in mapping]
    assert len(ids) == len(set(ids))
    assert all(entry["dataset_row"] in dataset_rows for entry in mapping)


def test_rejected_dataset_point_is_skipped():
    mapping = [{"destination_id": "34", "dataset_row": "10", "dataset_point": "reject"}]
    [decision] = decide_arrival_updates(mapping, [_row()], [PIN])
    assert decision.outcome == "skipped"


def test_pin_corrections_file_is_well_formed():
    from app.features.destinations.arrival_import import DATA_DIR, haversine_meters

    rows = read_csv(DATA_DIR / "pin_corrections.csv")
    assert rows
    for row in rows:
        assert row["source_url"].startswith("https://www.openstreetmap.org/")
        new = (float(row["new_lat"]), float(row["new_lng"]))
        assert 5.0 < new[0] < 8.5 and 125.0 < new[1] < 127.0  # Region XI
        if row["arrival_lat"]:
            gap = haversine_meters(*new, float(row["arrival_lat"]), float(row["arrival_lng"]))
            assert gap < 1500

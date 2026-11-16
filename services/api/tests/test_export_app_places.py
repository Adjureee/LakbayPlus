"""Tests for single-place export script."""

from __future__ import annotations

import csv
import importlib.util
from pathlib import Path


def _load_export_module():
    script_path = Path(__file__).resolve().parents[3] / "scripts" / "export_app_places.py"
    spec = importlib.util.spec_from_file_location("export_app_places", script_path)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def test_export_app_places_normalizes_rows_without_days_column(tmp_path: Path) -> None:
    mod = _load_export_module()
    out_csv = tmp_path / "places.csv"

    sample_rows = [
        {
            "destination_id": 7,
            "name": "Panabo City Parks and Plaza",
            "district": "Davao del Norte",
            "location": "National Highway, Panabo City, Davao del Norte, Philippines",
            "category": "Park / Public Plaza",
            "lat": 7.3081,
            "lng": 125.6842,
            "island_group": None,
            "stay_duration_type": "Short stay (1-2 hours)",
            "image_url": "https://res.cloudinary.com/demo/image/upload/v1/panabo.jpg",
            "overnight_fee": None,
        },
        {
            "destination_id": 40,
            "name": "Isla Reta Beach Resort",
            "district": "Davao del Norte",
            "location": "Santa Cruz, Island Garden City of Samal",
            "category": "beach resort",
            "lat": 6.9359,
            "lng": 125.7203,
            "island_group": "talikud",
            "stay_duration_type": None,
            "image_url": "https://res.cloudinary.com/demo/image/upload/v1/reta.jpg",
            "overnight_fee": "PHP 1500",
        },
    ]

    exported = mod.write_places_csv(sample_rows, out_csv)
    assert exported == 2

    with out_csv.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        assert reader.fieldnames == [
            "id",
            "name",
            "district",
            "category",
            "lat",
            "lng",
            "island_group",
            "stay_duration_type",
            "thumbnail",
        ]
        assert "days" not in reader.fieldnames
        rows = list(reader)

    assert rows[0]["id"] == "api_7"
    assert rows[0]["stay_duration_type"] == "short"
    assert rows[0]["category"] == "Park"
    assert rows[0]["district"] == "Panabo City, Davao del Norte"

    assert rows[1]["id"] == "api_40"
    assert rows[1]["island_group"] == "talikud"
    assert rows[1]["stay_duration_type"] == "overnight"
    assert rows[1]["category"] == "Beach Resort"

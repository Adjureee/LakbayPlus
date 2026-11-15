"""Region XI outline, OSM island detection, and the destination expansion pipeline."""

import asyncio
import json
from datetime import datetime, timezone

import pytest

from app.db.session import get_db_session
from app.features.ai.service import _parse_trip_draft
from app.features.destinations.models import DestinationCandidate
from app.features.destinations.region import island_group_for, province_for, region_status
from scripts import stage_osm_destination_candidates as importer
from tests.test_phase2_destination_data import admin_headers


@pytest.mark.parametrize(
    "lat,lng,province,island",
    [
        (7.0700, 125.6100, "Davao City", None),        # downtown
        (7.1220, 125.6630, "Davao City", None),        # Sasa, 1 km from Samal
        (7.0870, 125.6670, "Davao del Norte", "samal"),  # Samal west shore
        (7.1180, 125.6880, "Davao del Norte", "samal"),  # Babak landing
        (6.9530, 125.6990, "Davao del Norte", "talikud"),
        (7.2770, 125.8320, "Davao de Oro", "kopiat"),
        (5.4020, 125.3790, "Davao Occidental", "balut"),
        (6.9500, 126.2200, "Davao Oriental", None),     # Mati
    ],
)
def test_province_and_island_lookup(lat, lng, province, island) -> None:
    assert province_for(lat, lng) == province
    assert island_group_for(lat, lng) == island
    assert region_status(lat, lng) == "inside"


def test_places_outside_region_xi_are_outside() -> None:
    assert region_status(7.008, 125.089) == "outside"   # Kidapawan, Cotabato
    assert region_status(6.110, 125.170) == "outside"   # General Santos
    assert region_status(8.950, 125.530) == "outside"   # Butuan
    # Inside the old lat/lng rectangle, but not in the Davao Region.
    assert region_status(7.760, 125.000) == "outside"   # Bukidnon


def _stage(client, *, lat: float, lng: float, osm_id: int, name: str = "Island Beach") -> int:
    async def insert() -> int:
        async for session in client.app.dependency_overrides[get_db_session]():
            candidate = DestinationCandidate(
                osm_type="node", osm_id=osm_id,
                osm_url=f"https://www.openstreetmap.org/node/{osm_id}",
                source_area="Davao Del Norte", source_tag="natural=beach",
                name=name, lat=lat, lng=lng, suggested_category="beach",
                island_group=island_group_for(lat, lng),
            )
            session.add(candidate)
            await session.commit()
            await session.refresh(candidate)
            return candidate.candidate_id
        raise AssertionError("No test database session")

    return asyncio.run(insert())


def _ready_to_publish(client, base: str, headers: dict) -> None:
    response = client.patch(base, headers=headers, json={
        "category": "beach", "district": "Davao del Norte",
        "visitor_purpose": "Public beach for swimming",
        "access_policy": "public",
        "access_source_url": "https://example.org/beach-access",
        "access_verified_at": datetime.now(timezone.utc).isoformat(),
    })
    assert response.status_code == 200, response.text


def test_published_island_candidate_routes_as_island(client) -> None:
    headers = admin_headers(client)
    candidate_id = _stage(client, lat=7.0870, lng=125.6670, osm_id=880001)
    base = f"/api/v1/admin/destination-candidates/{candidate_id}"
    shown = client.get(base, headers=headers).json()
    assert shown["island_group"] == "samal"
    assert shown["region_status"] == "inside"
    _ready_to_publish(client, base, headers)

    published = client.post(f"{base}/publish", headers=headers)

    assert published.status_code == 200, published.text
    destination = client.get(
        f"/api/v1/destinations/{published.json()['destination_id']}"
    ).json()
    assert destination["island_group"] == "samal"


def test_moving_a_candidate_pin_updates_its_island(client) -> None:
    headers = admin_headers(client)
    candidate_id = _stage(client, lat=7.0870, lng=125.6670, osm_id=880002)
    base = f"/api/v1/admin/destination-candidates/{candidate_id}"

    moved = client.patch(base, headers=headers, json={"lat": 7.0700, "lng": 125.6100})

    assert moved.json()["island_group"] is None


def test_candidate_outside_region_cannot_be_published(client) -> None:
    headers = admin_headers(client)
    candidate_id = _stage(client, lat=7.008, lng=125.089, osm_id=880003, name="Far Spring")
    base = f"/api/v1/admin/destination-candidates/{candidate_id}"
    assert client.get(base, headers=headers).json()["region_status"] == "outside"
    _ready_to_publish(client, base, headers)

    response = client.post(f"{base}/publish", headers=headers)

    assert response.status_code == 422
    assert response.json()["error"]["code"] == "candidate_outside_davao_region"


def test_admin_created_destination_on_samal_is_tagged(client) -> None:
    from tests.test_phase6_routes import DESTINATION_A, create_destination

    headers = admin_headers(client)
    samal = create_destination(client, headers, {
        **DESTINATION_A, "name": "Samal Cove", "lat": 7.0870, "lng": 125.6670,
    })
    city = create_destination(client, headers, {**DESTINATION_A, "name": "City Park"})
    explicit = create_destination(client, headers, {
        **DESTINATION_A, "name": "Override", "lat": 7.0870, "lng": 125.6670,
        "island_group": "custom",
    })

    assert samal["island_group"] == "samal"
    assert city["island_group"] is None
    assert explicit["island_group"] == "custom"


def _row(osm_id: int, lat: float, lng: float, category: str, name: str) -> dict:
    return {
        "review_decision": "visitor_candidate_review", "osm_type": "node",
        "osm_id": osm_id, "osm_url": f"https://www.openstreetmap.org/node/{osm_id}",
        "latitude": lat, "longitude": lng, "source_area": "Davao City",
        "source_tag": f"x={category}", "name": name, "suggested_category": category,
        "same_osm_id_in_multiple_areas": False, "exact_seed_name_match": False,
    }


def test_prefill_and_priority() -> None:
    rows = [
        _row(1, 7.10, 125.60, "resort", "Zeta Resort"),
        _row(2, 7.0870, 125.6670, "beach", "Samal Sands"),
        _row(3, 7.20, 125.45, "waterfall", "City Falls"),
    ]

    ordered = importer.prioritized(rows)
    fields = importer.prefill(rows[1])

    assert [row["name"] for row in ordered] == ["City Falls", "Samal Sands", "Zeta Resort"]
    assert [row["name"] for row in importer.prioritized(rows, skip_resorts=True)] == [
        "City Falls", "Samal Sands",
    ]
    assert fields["district"] == "Davao del Norte"
    assert fields["island_group"] == "samal"
    assert fields["vibes"] == "beach, relaxed, sunny"


def test_stage_skips_rows_outside_region_and_respects_limit(client, tmp_path, monkeypatch) -> None:
    source = tmp_path / "review.jsonl"
    source.write_text("\n".join(json.dumps(row) for row in [
        _row(11, 7.20, 125.45, "waterfall", "City Falls"),
        _row(12, 7.008, 125.089, "waterfall", "Kidapawan Falls"),
        _row(13, 7.0870, 125.6670, "beach", "Samal Sands"),
        _row(14, 7.10, 125.60, "park", "Third Park"),
    ]), encoding="utf-8")

    async def bind():
        generator = client.app.dependency_overrides[get_db_session]()
        session = await anext(generator)
        try:
            return session.bind
        finally:
            await generator.aclose()

    from sqlalchemy.ext.asyncio import async_sessionmaker

    engine = asyncio.run(bind())
    monkeypatch.setattr(importer, "get_sessionmaker", lambda: async_sessionmaker(engine))

    added, skipped = asyncio.run(importer.stage(source, limit=2))

    assert added == 2
    assert skipped == 1  # Kidapawan
    headers = admin_headers(client)
    queue = client.get("/api/v1/admin/destination-candidates", headers=headers).json()
    items = queue["items"] if isinstance(queue, dict) else queue
    by_name = {item["name"]: item for item in items}
    assert set(by_name) == {"City Falls", "Samal Sands"}
    assert by_name["Samal Sands"]["island_group"] == "samal"
    assert by_name["City Falls"]["district"] == "Davao City"
    assert "verify access" in by_name["City Falls"]["review_notes"]


def test_trip_draft_clears_stops_outside_the_region_outline() -> None:
    draft = _parse_trip_draft(json.dumps({
        "reply": "Here you go.",
        "days": [{"activities": [
            {"title": "Samal beach", "lat": 7.0870, "lng": 125.6670},
            {"title": "Bukidnon (in the old box)", "lat": 7.760, "lng": 125.000},
        ]}],
    }))
    first, second = draft["days"][0]["activities"]
    assert (first["lat"], first["lng"]) == (7.0870, 125.6670)
    assert (second["lat"], second["lng"]) == (None, None)


def test_refresh_staged_fills_only_empty_fields(client, tmp_path, monkeypatch) -> None:
    source = tmp_path / "review.jsonl"
    source.write_text(json.dumps(_row(21, 7.0870, 125.6670, "beach", "Samal Sands")), encoding="utf-8")

    async def setup():
        async for session in client.app.dependency_overrides[get_db_session]():
            session.add(DestinationCandidate(
                osm_type="node", osm_id=21, osm_url="https://www.openstreetmap.org/node/21",
                source_area="Davao Del Norte", source_tag="natural=beach", name="Samal Sands",
                lat=7.0870, lng=125.6670, suggested_category="beach",
                district="Island Garden City of Samal",  # admin value: keep it
            ))
            await session.commit()
            return session.bind

    from sqlalchemy.ext.asyncio import async_sessionmaker

    engine = asyncio.run(setup())
    monkeypatch.setattr(importer, "get_sessionmaker", lambda: async_sessionmaker(engine))

    dry = asyncio.run(importer.refresh_staged(source, apply=False))
    applied = asyncio.run(importer.refresh_staged(source, apply=True))
    again = asyncio.run(importer.refresh_staged(source, apply=True))

    assert dry == applied
    assert applied["island_group"] == 1 and "district" not in applied
    assert again == {"staged_rows": 1}
    item = client.get(
        "/api/v1/admin/destination-candidates", headers=admin_headers(client),
    ).json()
    item = (item["items"] if isinstance(item, dict) else item)[0]
    assert item["district"] == "Island Garden City of Samal"
    assert item["island_group"] == "samal"
    assert item["category"] == "beach"

"""Offline verification tests for scripts.enrich_davao_catalog (no live prod mutations)."""

from __future__ import annotations

import io
import json
from datetime import datetime, timezone

import httpx
import pytest

from scripts import enrich_davao_catalog as mod


def test_all_curated_payloads_validate_against_pydantic_schemas() -> None:
    validated = mod.validate_plan_schemas(mod.ENRICHMENT_PLANS)
    assert len(validated) == len(mod.ENRICHMENT_PLANS)
    assert 1 in validated
    assert 31 in validated
    assert 63 in validated


def test_no_curated_plan_mutates_arrival_or_route_ready_fields() -> None:
    for plan in mod.ENRICHMENT_PLANS:
        overlap = mod.ARRIVAL_GUARD_FIELDS.intersection(plan.patch_fields)
        assert not overlap, f"{plan.destination_id} touched guarded fields: {overlap}"

    bad_plan = mod.DestinationEnrichmentPlan(
        destination_id=999,
        name="Unsafe Route Ready",
        source_urls=("https://example.com",),
        source_type="osm",
        patch_fields={"route_ready": True},
    )
    with pytest.raises(ValueError, match="guarded arrival/route_ready"):
        mod.validate_plan_schemas((bad_plan,))


def test_aqua_water_park_skips_conflicting_hours_but_upgrades_prices() -> None:
    aqua = next(p for p in mod.ENRICHMENT_PLANS if p.destination_id == 16)
    assert aqua.hours_payload is None
    assert aqua.prices_payload is not None
    assert str(aqua.prices_payload["prices"][0]["amount"]) == "570.00"
    quality = mod.project_data_quality(
        aqua,
        {"operating_hours": "Operator schedule conflicts on Tuesday", "entrance_fee": "Date-dependent"},
        now=datetime(2026, 11, 27, 5, 0, tzinfo=timezone.utc),
    )
    assert quality["hours"] == "estimated"
    assert quality["prices"] == "supported"


def test_data_quality_elevation_for_structured_and_text_only_places() -> None:
    now = datetime(2026, 11, 27, 5, 0, tzinfo=timezone.utc)
    peoples_park = next(p for p in mod.ENRICHMENT_PLANS if p.destination_id == 1)
    q1 = mod.project_data_quality(peoples_park, {}, now=now)
    assert q1 == {"hours": "supported", "prices": "supported", "activities": "supported"}

    casas = next(p for p in mod.ENRICHMENT_PLANS if p.destination_id == 32)
    q32 = mod.project_data_quality(casas, {}, now=now)
    assert q32 == {"hours": "supported", "prices": "supported", "activities": "supported"}

    hamiguitan = next(p for p in mod.ENRICHMENT_PLANS if p.destination_id == 37)
    q37 = mod.project_data_quality(hamiguitan, {}, now=now)
    assert q37["hours"] == "unknown"
    assert q37["prices"] == "estimated"


def test_chemas_clears_contaminated_discovery_samal_fields_idempotently() -> None:
    chemas = next(p for p in mod.ENRICHMENT_PLANS if p.destination_id == 63)
    dirty_live = {
        "destination_id": 63,
        "district": "Davao Del Norte",
        "category": "Boutique Nature Beach Resort...",
        "budget_class": "0",
        "activities": "Swimming across three outdoor infinity pools...",
        "overnight_fee": "18,000",
    }
    diff = mod.compute_patch_diff(dirty_live, chemas)
    assert diff["district"] == "Davao del Norte"
    assert diff["category"] == "beach resort"
    assert diff["budget_class"] == "premium"
    assert diff["activities"] is None
    assert diff["overnight_fee"] is None

    clean_live = {
        "destination_id": 63,
        "district": "Davao del Norte",
        "category": "beach resort",
        "budget_class": "premium",
        "activities": None,
        "overnight_fee": None,
    }
    assert mod.compute_patch_diff(clean_live, chemas) == {}


def test_offline_dry_run_succeeds_without_network() -> None:
    summary = mod.run_enrichment(apply=False, offline=True)
    assert summary["exit_code"] == 0
    assert summary["mode"] == "dry-run-offline"
    assert summary["counts"]["destinations_checked"] == len(mod.ENRICHMENT_PLANS)
    assert summary["counts"]["patch_planned_or_applied"] >= 30
    assert summary["counts"]["images_planned_or_applied"] == 4


def test_apply_missing_creds_exits_cleanly_without_secret_leaks(
    monkeypatch: pytest.MonkeyPatch, capsys: pytest.CaptureFixture[str],
) -> None:
    monkeypatch.delenv("LAKBAY_ADMIN_EMAIL", raising=False)
    monkeypatch.delenv("LAKBAY_ADMIN_PASSWORD", raising=False)
    rc = mod.main(["--apply"])
    assert rc == 2
    err = capsys.readouterr().err
    assert "LAKBAY_ADMIN_EMAIL" in err
    assert "LAKBAY_ADMIN_PASSWORD" in err


def test_staged_clips_honor_duration_and_size_trim_rules() -> None:
    assert len(mod.STAGED_CLIPS) >= 3
    for clip in mod.STAGED_CLIPS:
        assert clip.commons_page_url.startswith("https://commons.wikimedia.org/")
        assert clip.direct_url.startswith("https://upload.wikimedia.org/")
        assert clip.license_name
        assert clip.author
        exceeds_duration = clip.raw_duration_seconds > 15.0
        exceeds_size = (
            clip.raw_size_bytes > (10 * 1024 * 1024 if clip.media_type == "gif" else 15 * 1024 * 1024)
        )
        if exceeds_duration or exceeds_size:
            assert clip.requires_trim_transcode is True
            assert clip.ffmpeg_command is not None and "ffmpeg" in clip.ffmpeg_command


def test_apply_flow_get_before_put_preservation_and_idempotency(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("LAKBAY_ADMIN_EMAIL", "admin@example.com")
    monkeypatch.setenv("LAKBAY_ADMIN_PASSWORD", "super-secret-value-never-logged")

    # Seed an in-memory API state for IDs 1, 32, and 51 (51 missing image, 1 already has hours)
    state: dict[int, dict] = {
        1: {
            "destination_id": 1,
            "name": "People's Park",
            "district": "Davao City",
            "operating_hours": "Open daily",
            "operating_status": None,
            "booking_requirement": None,
            "how_to_get_there": None,
            "image_url": "https://res.cloudinary.com/demo/image/upload/v1/peoples_park.jpg",
        },
        32: {
            "destination_id": 32,
            "name": "Casas Con Vistas Resort",
            "district": "Davao del Norte",
            "location": "Igacos",
            "description": None,
            "activities": None,
            "estimated_cost": None,
            "budget_class": None,
            "operating_status": None,
            "booking_requirement": None,
            "best_time_to_visit": None,
            "best_time_basis": None,
            "how_to_get_there": None,
            "image_url": "https://res.cloudinary.com/demo/image/upload/v1/casas.jpg",
        },
        51: {
            "destination_id": 51,
            "name": "Tagum New City Hall",
            "district": "Davao Del Norte",
            "category": "Landmark",
            "budget_class": "0",
            "image_url": None,
        },
    }
    subresources: dict[int, dict[str, dict]] = {
        1: {
            # Pre-populated weekly hours must be preserved by GET-before-PUT check
            "hours": {"open_24_hours": False, "weekly": [{"weekday": 0, "is_closed": False}]},
            "prices": {"prices": []},
            "activities": {"activities": []},
        },
        32: {
            "hours": {"open_24_hours": None, "weekly": []},
            "prices": {"prices": []},
            "activities": {"activities": []},
        },
    }
    calls: list[tuple[str, str]] = []

    def api_handler(request: httpx.Request) -> httpx.Response:
        calls.append((request.method, request.url.path))
        path = request.url.path
        if request.method == "POST" and path == "/api/v1/auth/login":
            return httpx.Response(200, json={"tokens": {"access_token": "tok-123"}})
        if request.method == "GET" and path == "/api/v1/destinations":
            offset = int(request.url.params.get("offset", "0"))
            rows = list(state.values())[offset : offset + 100]
            return httpx.Response(200, json=rows)

        parts = path.removeprefix("/api/v1/destinations/").split("/")
        dest_id = int(parts[0])
        if len(parts) == 1 and request.method == "PATCH":
            assert request.headers.get("Authorization") == "Bearer tok-123"
            body = json.loads(request.content.decode("utf-8"))
            state[dest_id].update(body)
            return httpx.Response(200, json=state[dest_id])

        if len(parts) == 2 and parts[1] in {"hours", "prices", "activities"}:
            sub = parts[1]
            if request.method == "GET":
                return httpx.Response(200, json=subresources.get(dest_id, {}).get(sub, {}))
            if request.method == "PUT":
                assert request.headers.get("Authorization") == "Bearer tok-123"
                body = json.loads(request.content.decode("utf-8"))
                subresources.setdefault(dest_id, {})[sub] = body
                return httpx.Response(200, json=body)

        if len(parts) == 2 and parts[1] == "image" and request.method == "POST":
            assert request.headers.get("Authorization") == "Bearer tok-123"
            assert b"\xff\xd8\xff" in request.content
            state[dest_id]["image_url"] = f"https://res.cloudinary.com/demo/image/upload/v1/dest_{dest_id}.jpg"
            return httpx.Response(200, json=state[dest_id])

        return httpx.Response(404, json={"detail": "not found"})

    def img_handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(200, content=b"\xff\xd8\xff\xe0MOCKJPEGDATA")

    api_client = httpx.Client(
        base_url="https://mock.lakbay.local/api/v1",
        transport=httpx.MockTransport(api_handler),
    )
    img_client = httpx.Client(transport=httpx.MockTransport(img_handler))

    # Pass 1: applies patches, preserves ID 1 existing hours, writes ID 32 subresources, uploads ID 51 image
    res1 = mod.run_enrichment(
        apply=True,
        only_ids={1, 32, 51},
        api_client=api_client,
        image_fetcher=img_client,
    )
    assert res1["mode"] == "live-applied"
    assert ("PUT", "/api/v1/destinations/1/hours") not in calls  # preserved!
    assert ("PUT", "/api/v1/destinations/1/prices") in calls
    assert ("PUT", "/api/v1/destinations/32/hours") in calls
    assert ("PUT", "/api/v1/destinations/32/prices") in calls
    assert ("PUT", "/api/v1/destinations/32/activities") in calls
    assert ("POST", "/api/v1/destinations/51/image") in calls
    assert state[51]["district"] == "Davao del Norte"
    assert state[51]["budget_class"] == "budget"
    assert state[51]["image_url"].startswith("https://res.cloudinary.com/")

    # Pass 2: idempotency check (must emit 0 PATCH/PUT/POST writes)
    calls.clear()
    res2 = mod.run_enrichment(
        apply=True,
        only_ids={1, 32, 51},
        api_client=api_client,
        image_fetcher=img_client,
    )
    write_calls = [c for c in calls if c[0] in {"PATCH", "PUT", "POST"} and not c[1].endswith("/auth/login")]
    assert write_calls == []
    assert res2["counts"]["patch_planned_or_applied"] == 0
    assert res2["counts"]["images_planned_or_applied"] == 0
    assert "super-secret-value-never-logged" not in json.dumps(res1)
    assert "super-secret-value-never-logged" not in json.dumps(res2)

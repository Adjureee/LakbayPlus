from datetime import datetime

from tests.e2e.conftest import FakeStorageClient
from tests.e2e.helpers import (
    enrich_destination_d6,
    make_gif89a_bytes,
    make_jpeg_bytes,
    make_mp4_bytes,
    make_png_bytes,
    make_webp_bytes,
    make_webm_bytes,
    register_admin,
    register_user,
    seed_destination,
    seed_trip,
)


# ---------------------------------------------------------------------------
# F6 (R6) — Trip Completion Lifecycle
# ---------------------------------------------------------------------------


def test_f6_create_trip_and_transition_planned_to_ongoing(client) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    stop = seed_destination(client, admin_headers, name="People's Park")

    trip = seed_trip(client, user_headers, [stop["destination_id"]])
    assert trip["status"] == "planned"
    assert trip["completed_at"] is None

    resp = client.patch(
        f"/api/v1/trips/{trip['trip_id']}",
        headers=user_headers,
        json={"status": "ongoing"},
    )
    assert resp.status_code == 200, resp.text
    updated = resp.json()
    assert updated["status"] == "ongoing"
    assert updated["completed_at"] is None


def test_f6_transition_ongoing_to_completed_populates_completed_at(client) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    stop = seed_destination(client, admin_headers, name="Eden Nature Park")
    trip = seed_trip(client, user_headers, [stop["destination_id"]])

    r1 = client.patch(
        f"/api/v1/trips/{trip['trip_id']}",
        headers=user_headers,
        json={"status": "ongoing"},
    )
    assert r1.status_code == 200, r1.text

    r2 = client.patch(
        f"/api/v1/trips/{trip['trip_id']}",
        headers=user_headers,
        json={"status": "completed"},
    )
    assert r2.status_code == 200, r2.text
    completed = r2.json()
    assert completed["status"] == "completed"
    assert completed["completed_at"] is not None
    # Verify ISO-8601 parseable timestamp
    datetime.fromisoformat(completed["completed_at"].replace("Z", "+00:00"))


def test_f6_reopen_completed_to_planned_clears_completed_at(client) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    stop = seed_destination(client, admin_headers, name="Malagos Garden")
    trip = seed_trip(client, user_headers, [stop["destination_id"]])

    r_complete = client.patch(
        f"/api/v1/trips/{trip['trip_id']}",
        headers=user_headers,
        json={"status": "completed"},
    )
    assert r_complete.status_code == 200, r_complete.text
    assert r_complete.json()["completed_at"] is not None

    r_reopen = client.patch(
        f"/api/v1/trips/{trip['trip_id']}",
        headers=user_headers,
        json={"status": "planned"},
    )
    assert r_reopen.status_code == 200, r_reopen.text
    reopened = r_reopen.json()
    assert reopened["status"] == "planned"
    assert reopened["completed_at"] is None


def test_f6_get_trips_and_detail_reflect_status_and_completed_at(client) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    stop = seed_destination(client, admin_headers, name="Davao Museum")
    trip = seed_trip(client, user_headers, [stop["destination_id"]])

    r_complete = client.patch(
        f"/api/v1/trips/{trip['trip_id']}",
        headers=user_headers,
        json={"status": "completed"},
    )
    assert r_complete.status_code == 200, r_complete.text
    completed_at = r_complete.json()["completed_at"]
    assert completed_at is not None

    list_resp = client.get("/api/v1/trips", headers=user_headers)
    assert list_resp.status_code == 200, list_resp.text
    listed = next(item for item in list_resp.json() if item["trip_id"] == trip["trip_id"])
    assert listed["status"] == "completed"
    assert listed["completed_at"] == completed_at

    detail_resp = client.get(f"/api/v1/trips/{trip['trip_id']}", headers=user_headers)
    assert detail_resp.status_code == 200, detail_resp.text
    assert detail_resp.json()["status"] == "completed"
    assert detail_resp.json()["completed_at"] == completed_at


def test_f6_admin_trips_filter_and_completed_at_visibility(client) -> None:
    admin_headers, _ = register_admin(client)
    user_headers, _ = register_user(client)
    stop = seed_destination(client, admin_headers, name="Samal Hagimit")
    trip_done = seed_trip(client, user_headers, [stop["destination_id"]], title="Done Samal Trip")
    trip_open = seed_trip(client, user_headers, [stop["destination_id"]], title="Open Samal Trip")

    r_done = client.patch(
        f"/api/v1/trips/{trip_done['trip_id']}",
        headers=user_headers,
        json={"status": "completed"},
    )
    assert r_done.status_code == 200, r_done.text

    resp = client.get(
        "/api/v1/admin/trips",
        headers=admin_headers,
        params={"status": "completed"},
    )
    assert resp.status_code == 200, resp.text
    items = resp.json()["items"]
    ids = {item["trip_id"] for item in items}
    assert trip_done["trip_id"] in ids
    assert trip_open["trip_id"] not in ids
    matched = next(item for item in items if item["trip_id"] == trip_done["trip_id"])
    assert matched["status"] == "completed"
    assert matched["completed_at"] is not None


# ---------------------------------------------------------------------------
# F7 (R7) — Destination Media (Image / GIF / MP4 / WebM) & D6 Enrichment
# ---------------------------------------------------------------------------


def test_f7_admin_upload_image_updates_image_url(client, e2e_fakes) -> None:
    admin_headers, _ = register_admin(client)
    dest = seed_destination(client, admin_headers, name="Jack's Ridge Overlook")
    dest_id = dest["destination_id"]

    for filename, payload, content_type in (
        ("ridge.jpg", make_jpeg_bytes(), "image/jpeg"),
        ("ridge.png", make_png_bytes(), "image/png"),
        ("ridge.webp", make_webp_bytes(), "image/webp"),
    ):
        resp = client.post(
            f"/api/v1/destinations/{dest_id}/image",
            headers=admin_headers,
            files={"file": (filename, payload, content_type)},
        )
        assert resp.status_code == 200, resp.text
        body = resp.json()
        assert body["image_url"]
        assert body["image_url"].startswith("https://res.cloudinary.com/")

    assert len(e2e_fakes.storage.calls) == 3


def test_f7_admin_upload_gif_sets_media_url_and_poster(client) -> None:
    admin_headers, _ = register_admin(client)
    dest = seed_destination(client, admin_headers, name="Dahican Wave Loop")
    dest_id = dest["destination_id"]

    resp = client.post(
        f"/api/v1/destinations/{dest_id}/media",
        headers=admin_headers,
        files={"file": ("waves.gif", make_gif89a_bytes(), "image/gif")},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["media_type"] == "gif"
    assert body["media_url"].endswith(".gif")
    assert body["image_url"]
    assert "pg_1,f_jpg,q_auto" in body["image_url"]

    # Subsequent GIF upload preserves existing non-empty image_url poster
    existing_poster = "https://res.cloudinary.com/demo/image/upload/v1/lakbay/custom-poster.jpg"
    patch_resp = client.patch(
        f"/api/v1/destinations/{dest_id}",
        headers=admin_headers,
        json={"image_url": existing_poster},
    )
    assert patch_resp.status_code == 200, patch_resp.text

    resp2 = client.post(
        f"/api/v1/destinations/{dest_id}/media",
        headers=admin_headers,
        files={"file": ("waves2.gif", make_gif89a_bytes(), "image/gif")},
    )
    assert resp2.status_code == 200, resp2.text
    assert resp2.json()["image_url"] == existing_poster
    assert resp2.json()["media_type"] == "gif"


def test_f7_admin_upload_mp4_clip_returns_video_metadata_and_poster(client) -> None:
    admin_headers, _ = register_admin(client)
    dest = seed_destination(client, admin_headers, name="Aliwagwag Falls")
    dest_id = dest["destination_id"]

    resp = client.post(
        f"/api/v1/destinations/{dest_id}/media",
        headers=admin_headers,
        files={"file": ("falls.mp4", make_mp4_bytes(duration_seconds=8.5), "video/mp4")},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["media_type"] == "video"
    assert body["media_url"].endswith(".mp4")
    assert body["media_duration_seconds"] == 8.5
    assert body["image_url"]
    assert "so_0,f_jpg,q_auto" in body["image_url"]


def test_f7_admin_upload_webm_clip_returns_video_metadata(client, e2e_fakes) -> None:
    admin_headers, _ = register_admin(client)
    dest = seed_destination(client, admin_headers, name="Marilog Pine Ridge")
    dest_id = dest["destination_id"]

    e2e_fakes.storage = FakeStorageClient()
    resp = client.post(
        f"/api/v1/destinations/{dest_id}/media",
        headers=admin_headers,
        files={"file": ("pine.webm", make_webm_bytes(duration_ms=10_000.0), "video/webm")},
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["media_type"] == "video"
    assert body["media_url"].endswith(".webm")
    assert body["media_duration_seconds"] == 10.0


def test_f7_get_destination_returns_media_and_d6_enrichment_fields(client) -> None:
    admin_headers, _ = register_admin(client)
    dest = seed_destination(client, admin_headers, name="Philippine Eagle Center")
    dest_id = dest["destination_id"]

    enrich_destination_d6(
        client,
        admin_headers,
        dest_id,
        image_credit="Philippine Eagle Foundation",
        image_license="CC-BY-SA-4.0",
        image_source_url="https://commons.wikimedia.org/wiki/File:Philippine_Eagle_Davao.jpg",
    )
    upload_resp = client.post(
        f"/api/v1/destinations/{dest_id}/media",
        headers=admin_headers,
        files={"file": ("eagle.mp4", make_mp4_bytes(duration_seconds=6.0), "video/mp4")},
    )
    assert upload_resp.status_code == 200, upload_resp.text

    detail = client.get(f"/api/v1/destinations/{dest_id}")
    assert detail.status_code == 200, detail.text
    body = detail.json()
    assert body["media_type"] == "video"
    assert body["media_url"]
    assert body["media_duration_seconds"] == 6.0
    assert body["image_url"]
    assert body["image_credit"] == "Philippine Eagle Foundation"
    assert body["image_license"] == "CC-BY-SA-4.0"
    assert body["image_source_url"] == "https://commons.wikimedia.org/wiki/File:Philippine_Eagle_Davao.jpg"

    hours = client.get(f"/api/v1/destinations/{dest_id}/hours")
    assert hours.status_code == 200
    assert len(hours.json()["weekly"]) == 7

    prices = client.get(f"/api/v1/destinations/{dest_id}/prices")
    assert prices.status_code == 200
    assert len(prices.json()["prices"]) == 2

    activities = client.get(f"/api/v1/destinations/{dest_id}/activities")
    assert activities.status_code == 200
    assert activities.json()["activities"][0]["name"] == "Guided Canopy Walk"

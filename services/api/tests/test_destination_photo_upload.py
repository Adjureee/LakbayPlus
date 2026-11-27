import struct
from typing import Literal

from app.integrations.storage.client import (
    CloudinaryStorageClient,
    StorageUploadResult,
    get_storage_client,
)
from app.integrations.storage.uploads import (
    MEDIA_MAX_DURATION_SECONDS,
    MEDIA_MAX_IMAGE_BYTES,
    MEDIA_MAX_VIDEO_BYTES,
    extract_video_duration_seconds,
)
from tests.test_phase2_destination_data import (
    admin_headers,
    create_destination,
    user_headers,
)

JPEG_BYTES = b"\xff\xd8\xff\xe0destination-photo"
GIF89A_BYTES = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xff\xff\xff!\xf9\x04\x01\x00\x00\x00\x00,\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02D\x01\x00;"
GIF87A_BYTES = b"GIF87a\x01\x00\x01\x00\x00\x00\x00;"
MP4_MINIMAL_BYTES = b"\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom"
WEBM_MINIMAL_BYTES = b"\x1a\x45\xdf\xa3\x9f\x42\x86\x81\x01"
NEW_URL = "https://res.cloudinary.com/demo/image/upload/lakbay/destinations/1/beach.jpg"
NEW_GIF_URL = "https://res.cloudinary.com/demo/image/upload/v1/lakbay/destinations/1/beach.gif"
NEW_VIDEO_URL = "https://res.cloudinary.com/demo/video/upload/v1/lakbay/destinations/1/beach.mp4"


def _build_mp4_with_mvhd(duration_seconds: float, timescale: int = 1000) -> bytes:
    duration_units = int(round(duration_seconds * timescale))
    # mvhd version 0: 4 bytes version/flags + 8 bytes creation/mod + 4 timescale + 4 duration + 80 rest = 100 bytes payload
    mvhd_payload = struct.pack(">IIII", 0, 0, 0, timescale) + struct.pack(">I", duration_units) + (b"\x00" * 80)
    mvhd_box = struct.pack(">I4s", 8 + len(mvhd_payload), b"mvhd") + mvhd_payload
    moov_box = struct.pack(">I4s", 8 + len(mvhd_box), b"moov") + mvhd_box
    return MP4_MINIMAL_BYTES + moov_box


def _build_webm_with_duration(duration_ms: float) -> bytes:
    # EBML header (4B id + 1B size=4 + 4B EBMLVersion=1)
    ebml_header = b"\x1a\x45\xdf\xa3\x84\x42\x86\x81\x01"
    # TimecodeScale = 1_000_000 (1ms), Duration float64 = duration_ms
    ts_payload = (1_000_000).to_bytes(3, "big")
    ts_elem = b"\x2a\xd7\xb1" + bytes([0x80 | len(ts_payload)]) + ts_payload
    dur_payload = struct.pack(">d", duration_ms)
    dur_elem = b"\x44\x89" + bytes([0x80 | len(dur_payload)]) + dur_payload
    info_payload = ts_elem + dur_elem
    info_elem = b"\x15\x49\xa9\x66" + bytes([0x80 | len(info_payload)]) + info_payload
    seg_elem = b"\x18\x53\x80\x67" + bytes([0x80 | len(info_elem)]) + info_elem
    return ebml_header + seg_elem


class FakeStorageClient:
    def __init__(
        self,
        *,
        media_url: str | None = None,
        media_duration: float | None = None,
    ) -> None:
        self.calls: list[dict] = []
        self.media_calls: list[dict] = []
        self.deleted_calls: list[dict] = []
        self.media_url = media_url
        self.media_duration = media_duration

    async def upload_image(
        self,
        *,
        file_bytes: bytes,
        filename: str | None,
        content_type: str,
        folder_suffix: str | None = None,
    ) -> StorageUploadResult:
        self.calls.append(
            {
                "file_bytes": file_bytes,
                "filename": filename,
                "content_type": content_type,
                "folder_suffix": folder_suffix,
            }
        )
        return StorageUploadResult(
            image_url=NEW_URL,
            cloudinary_public_id="lakbay/destinations/1/beach",
            original_filename=filename,
            content_type=content_type,
            bytes=len(file_bytes),
            format="jpg",
            resource_type="image",
        )

    async def upload_media(
        self,
        *,
        file_bytes: bytes,
        filename: str | None,
        content_type: str,
        resource_type: Literal["image", "video"] = "image",
        folder_suffix: str | None = None,
    ) -> StorageUploadResult:
        self.media_calls.append(
            {
                "file_bytes": file_bytes,
                "filename": filename,
                "content_type": content_type,
                "resource_type": resource_type,
                "folder_suffix": folder_suffix,
            }
        )
        default_url = (
            NEW_VIDEO_URL
            if resource_type == "video"
            else (NEW_GIF_URL if content_type == "image/gif" else NEW_URL)
        )
        return StorageUploadResult(
            image_url=self.media_url or default_url,
            cloudinary_public_id="lakbay/destinations/1/clip",
            original_filename=filename,
            content_type=content_type,
            bytes=len(file_bytes),
            format="mp4" if resource_type == "video" else ("gif" if content_type == "image/gif" else "jpg"),
            resource_type=resource_type,
            duration=self.media_duration,
        )

    async def delete_media(
        self,
        public_id: str,
        *,
        resource_type: Literal["image", "video"] = "image",
    ) -> str:
        self.deleted_calls.append(
            {"public_id": public_id, "resource_type": resource_type}
        )
        return "ok"


def _use_fake_storage(
    client,
    *,
    media_url: str | None = None,
    media_duration: float | None = None,
) -> FakeStorageClient:
    storage = FakeStorageClient(
        media_url=media_url,
        media_duration=media_duration,
    )
    client.app.dependency_overrides[get_storage_client] = lambda: storage
    return storage


def test_admin_upload_sets_destination_photo(client) -> None:
    headers = admin_headers(client)
    destination = create_destination(client, headers)
    storage = _use_fake_storage(client)

    response = client.post(
        f"/api/v1/destinations/{destination['destination_id']}/image",
        headers=headers,
        files={"file": ("beach.jpg", JPEG_BYTES, "image/jpeg")},
    )

    assert response.status_code == 200
    assert response.json()["image_url"] == NEW_URL
    assert storage.calls == [
        {
            "file_bytes": JPEG_BYTES,
            "filename": "beach.jpg",
            "content_type": "image/jpeg",
            "folder_suffix": f"destinations/{destination['destination_id']}",
        }
    ]
    # Travelers see the new photo through the public endpoint.
    public = client.get(f"/api/v1/destinations/{destination['destination_id']}")
    assert public.json()["image_url"] == NEW_URL


def test_non_admin_cannot_upload_destination_photo(client) -> None:
    destination = create_destination(client)
    storage = _use_fake_storage(client)

    response = client.post(
        f"/api/v1/destinations/{destination['destination_id']}/image",
        headers=user_headers(client),
        files={"file": ("beach.jpg", JPEG_BYTES, "image/jpeg")},
    )

    assert response.status_code == 403
    assert storage.calls == []


def test_upload_to_unknown_destination_is_404(client) -> None:
    headers = admin_headers(client)
    storage = _use_fake_storage(client)

    response = client.post(
        "/api/v1/destinations/9999/image",
        headers=headers,
        files={"file": ("beach.jpg", JPEG_BYTES, "image/jpeg")},
    )

    assert response.status_code == 404
    assert storage.calls == []


def test_non_image_upload_is_rejected_before_cloudinary(client) -> None:
    headers = admin_headers(client)
    destination = create_destination(client, headers)
    storage = _use_fake_storage(client)

    response = client.post(
        f"/api/v1/destinations/{destination['destination_id']}/image",
        headers=headers,
        files={"file": ("notes.jpg", b"not really an image", "image/jpeg")},
    )

    assert response.status_code == 400
    assert storage.calls == []
    unchanged = client.get(f"/api/v1/destinations/{destination['destination_id']}")
    assert unchanged.json()["image_url"] != NEW_URL


def test_admin_upload_media_gif_preserves_existing_poster_or_derives_static(client) -> None:
    headers = admin_headers(client)
    dest_with_poster = create_destination(client, headers)
    patch = client.patch(
        f"/api/v1/destinations/{dest_with_poster['destination_id']}",
        headers=headers,
        json={"image_url": NEW_URL},
    )
    assert patch.status_code == 200

    storage = _use_fake_storage(client)
    resp1 = client.post(
        f"/api/v1/destinations/{dest_with_poster['destination_id']}/media",
        headers=headers,
        files={"file": ("wave.gif", GIF89A_BYTES, "image/gif")},
    )
    assert resp1.status_code == 200
    body1 = resp1.json()
    assert body1["media_url"] == NEW_GIF_URL
    assert body1["media_type"] == "gif"
    assert body1["media_duration_seconds"] is None
    # Existing poster preserved.
    assert body1["image_url"] == NEW_URL

    # Without an existing poster, a static frame-1 JPG poster is derived on Cloudinary.
    dest_no_poster = create_destination(client, headers)
    resp2 = client.post(
        f"/api/v1/destinations/{dest_no_poster['destination_id']}/media",
        headers=headers,
        files={"file": ("legacy.gif", GIF87A_BYTES, "image/gif")},
    )
    assert resp2.status_code == 200
    body2 = resp2.json()
    assert body2["media_url"] == NEW_GIF_URL
    assert body2["media_type"] == "gif"
    assert body2["image_url"] == (
        "https://res.cloudinary.com/demo/image/upload/pg_1,f_jpg,q_auto/"
        "v1/lakbay/destinations/1/beach.jpg"
    )
    assert storage.media_calls[0]["resource_type"] == "image"


def test_admin_upload_media_video_mp4_and_webm_poster_rules(client) -> None:
    headers = admin_headers(client)
    # 1. Cloudinary video without existing image_url derives so_0,f_jpg poster.
    dest1 = create_destination(client, headers)
    storage = _use_fake_storage(client, media_duration=8.4)
    mp4_ok = _build_mp4_with_mvhd(8.4)
    resp1 = client.post(
        f"/api/v1/destinations/{dest1['destination_id']}/media",
        headers=headers,
        files={"file": ("clip.mp4", mp4_ok, "video/mp4")},
    )
    assert resp1.status_code == 200
    body1 = resp1.json()
    assert body1["media_url"] == NEW_VIDEO_URL
    assert body1["media_type"] == "video"
    assert body1["media_duration_seconds"] == 8.4
    assert body1["image_url"] == (
        "https://res.cloudinary.com/demo/video/upload/so_0,f_jpg,q_auto/"
        "v1/lakbay/destinations/1/beach.jpg"
    )
    assert storage.media_calls[0]["resource_type"] == "video"

    # 2. Non-Cloudinary video URL must NEVER be copied into image_url.
    dest2 = create_destination(client, headers)
    _use_fake_storage(
        client,
        media_url="https://cdn.example.test/clips/drone.webm",
        media_duration=6.2,
    )
    webm_ok = _build_webm_with_duration(6200.0)
    resp2 = client.post(
        f"/api/v1/destinations/{dest2['destination_id']}/media",
        headers=headers,
        files={"file": ("drone.webm", webm_ok, "video/webm")},
    )
    assert resp2.status_code == 200
    body2 = resp2.json()
    assert body2["media_url"] == "https://cdn.example.test/clips/drone.webm"
    assert body2["media_type"] == "video"
    assert body2["media_duration_seconds"] == 6.2
    assert body2["image_url"] is None


def test_admin_upload_media_static_image_updates_both_fields(client) -> None:
    headers = admin_headers(client)
    dest = create_destination(client, headers)
    _use_fake_storage(client)

    resp = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=headers,
        files={"file": ("photo.jpg", JPEG_BYTES, "image/jpeg")},
    )
    assert resp.status_code == 200
    body = resp.json()
    assert body["media_url"] == NEW_URL
    assert body["media_type"] == "image"
    assert body["image_url"] == NEW_URL


def test_media_upload_enforces_size_caps_and_octet_stream_gif_limit(client) -> None:
    headers = admin_headers(client)
    dest = create_destination(client, headers)
    storage = _use_fake_storage(client)

    oversized_gif = GIF89A_BYTES + (b"0" * (MEDIA_MAX_IMAGE_BYTES + 1 - len(GIF89A_BYTES)))
    resp_gif = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=headers,
        files={"file": ("big.gif", oversized_gif, "image/gif")},
    )
    assert resp_gif.status_code == 400
    assert resp_gif.json()["error"]["code"] == "upload_too_large"

    # Spoofed as octet-stream: still rejected once sniffed as >10 MB GIF.
    resp_sniff = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=headers,
        files={"file": ("big.bin", oversized_gif, "application/octet-stream")},
    )
    assert resp_sniff.status_code == 400
    assert resp_sniff.json()["error"]["code"] == "upload_too_large"

    oversized_mp4 = MP4_MINIMAL_BYTES + (
        b"0" * (MEDIA_MAX_VIDEO_BYTES + 1 - len(MP4_MINIMAL_BYTES))
    )
    resp_mp4 = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=headers,
        files={"file": ("huge.mp4", oversized_mp4, "video/mp4")},
    )
    assert resp_mp4.status_code == 400
    assert resp_mp4.json()["error"]["code"] == "upload_too_large"
    assert storage.media_calls == []


def test_media_upload_rejects_spoofed_mime_and_invalid_content(client) -> None:
    headers = admin_headers(client)
    dest = create_destination(client, headers)
    storage = _use_fake_storage(client)

    resp_invalid = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=headers,
        files={"file": ("fake.mp4", b"not-a-video", "video/mp4")},
    )
    assert resp_invalid.status_code == 400
    assert resp_invalid.json()["error"]["code"] == "invalid_media_content"

    resp_mismatch = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=headers,
        files={"file": ("anim.png", GIF89A_BYTES, "image/png")},
    )
    assert resp_mismatch.status_code == 400
    assert resp_mismatch.json()["error"]["code"] == "media_type_mismatch"
    assert storage.media_calls == []


def test_media_upload_rejects_over_15s_pre_upload_and_post_upload(client) -> None:
    headers = admin_headers(client)
    dest = create_destination(client, headers)
    storage = _use_fake_storage(client, media_duration=16.2)

    # 1. Pre-upload MP4 mvhd duration > 15s never reaches Cloudinary.
    long_mp4 = _build_mp4_with_mvhd(18.0)
    resp_pre_mp4 = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=headers,
        files={"file": ("long.mp4", long_mp4, "video/mp4")},
    )
    assert resp_pre_mp4.status_code == 400
    assert resp_pre_mp4.json()["error"]["code"] == "media_duration_exceeded"
    assert storage.media_calls == []

    # 2. Pre-upload WebM EBML duration > 15s never reaches Cloudinary.
    long_webm = _build_webm_with_duration(17_500.0)
    assert round(extract_video_duration_seconds(long_webm, "video/webm") or 0, 1) == 17.5
    resp_pre_webm = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=headers,
        files={"file": ("long.webm", long_webm, "video/webm")},
    )
    assert resp_pre_webm.status_code == 400
    assert resp_pre_webm.json()["error"]["code"] == "media_duration_exceeded"
    assert storage.media_calls == []

    # 3. Minimal MP4 without mvhd passes pre-check, Cloudinary reports 16.2s -> deleted + 400.
    resp_post = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=headers,
        files={"file": ("stream.mp4", MP4_MINIMAL_BYTES, "video/mp4")},
    )
    assert resp_post.status_code == 400
    assert resp_post.json()["error"]["code"] == "media_duration_exceeded"
    assert resp_post.json()["error"]["details"]["max_duration_seconds"] == MEDIA_MAX_DURATION_SECONDS
    assert len(storage.media_calls) == 1
    assert storage.deleted_calls == [
        {"public_id": "lakbay/destinations/1/clip", "resource_type": "video"}
    ]
    unchanged = client.get(f"/api/v1/destinations/{dest['destination_id']}").json()
    assert unchanged["media_url"] is None


def test_media_upload_auth_and_not_found(client) -> None:
    headers = admin_headers(client)
    dest = create_destination(client, headers)
    storage = _use_fake_storage(client)

    forbidden = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=user_headers(client),
        files={"file": ("wave.gif", GIF89A_BYTES, "image/gif")},
    )
    assert forbidden.status_code == 403

    missing = client.post(
        "/api/v1/destinations/99999/media",
        headers=headers,
        files={"file": ("wave.gif", GIF89A_BYTES, "image/gif")},
    )
    assert missing.status_code == 404
    assert storage.media_calls == []


def test_patch_destination_attribution_and_media_clear(client) -> None:
    headers = admin_headers(client)
    dest = create_destination(client, headers)
    _use_fake_storage(client, media_duration=7.0)
    up = client.post(
        f"/api/v1/destinations/{dest['destination_id']}/media",
        headers=headers,
        files={"file": ("clip.mp4", _build_mp4_with_mvhd(7.0), "video/mp4")},
    )
    assert up.status_code == 200
    assert up.json()["media_url"] == NEW_VIDEO_URL

    invalid_url = client.patch(
        f"/api/v1/destinations/{dest['destination_id']}",
        headers=headers,
        json={"image_source_url": "ftp://bad.example/file.jpg"},
    )
    assert invalid_url.status_code == 422

    patched = client.patch(
        f"/api/v1/destinations/{dest['destination_id']}",
        headers=headers,
        json={
            "image_credit": "Davao Tourism Archive",
            "image_license": "CC-BY-4.0",
            "image_source_url": "https://commons.wikimedia.org/wiki/File:Samal.jpg",
            "media_url": None,
            "media_type": None,
            "media_public_id": None,
            "media_duration_seconds": None,
        },
    )
    assert patched.status_code == 200
    body = patched.json()
    assert body["image_credit"] == "Davao Tourism Archive"
    assert body["image_license"] == "CC-BY-4.0"
    assert body["image_source_url"] == "https://commons.wikimedia.org/wiki/File:Samal.jpg"
    assert body["media_url"] is None
    assert body["media_type"] is None
    assert body["media_public_id"] is None
    assert body["media_duration_seconds"] is None


def test_cloudinary_storage_client_upload_and_delete_media(monkeypatch) -> None:
    import asyncio
    from types import SimpleNamespace
    import cloudinary
    import cloudinary.uploader

    captured: list[dict] = []
    destroyed: list[dict] = []

    def fake_upload(file_obj, **kwargs):
        captured.append(kwargs)
        return {
            "secure_url": NEW_VIDEO_URL if kwargs["resource_type"] == "video" else NEW_GIF_URL,
            "public_id": "lakbay/destinations/1/clip",
            "bytes": 1024,
            "format": "mp4" if kwargs["resource_type"] == "video" else "gif",
            "resource_type": kwargs["resource_type"],
            "duration": 9.5 if kwargs["resource_type"] == "video" else None,
        }

    def fake_destroy(public_id, **kwargs):
        destroyed.append({"public_id": public_id, **kwargs})
        return {"result": "ok"}

    monkeypatch.setattr(cloudinary.uploader, "upload", fake_upload)
    monkeypatch.setattr(cloudinary.uploader, "destroy", fake_destroy)
    settings = SimpleNamespace(
        cloudinary_cloud_name="demo",
        cloudinary_api_key="key",
        cloudinary_api_secret="secret",
        cloudinary_upload_folder="lakbay",
    )
    client = CloudinaryStorageClient(settings)  # type: ignore[arg-type]

    async def _run() -> None:
        gif_res = await client.upload_media(
            file_bytes=GIF89A_BYTES,
            filename="wave.gif",
            content_type="image/gif",
            resource_type="image",
            folder_suffix="destinations/1",
        )
        assert gif_res.image_url == NEW_GIF_URL
        assert "transformation" not in captured[0]  # GIF frames preserved

        vid_res = await client.upload_media(
            file_bytes=MP4_MINIMAL_BYTES,
            filename="clip.mp4",
            content_type="video/mp4",
            resource_type="video",
            folder_suffix="destinations/1",
        )
        assert vid_res.duration == 9.5
        assert captured[1]["resource_type"] == "video"
        assert captured[1]["transformation"] == {"width": 1080, "crop": "limit", "quality": "auto"}

        outcome = await client.delete_media("lakbay/destinations/1/clip", resource_type="video")
        assert outcome == "ok"
        assert destroyed == [
            {
                "public_id": "lakbay/destinations/1/clip",
                "resource_type": "video",
                "invalidate": True,
            }
        ]

    asyncio.run(_run())

from app.integrations.storage.client import StorageUploadResult, get_storage_client
from tests.test_phase2_destination_data import (
    admin_headers,
    create_destination,
    user_headers,
)

JPEG_BYTES = b"\xff\xd8\xff\xe0destination-photo"
NEW_URL = "https://res.cloudinary.com/demo/image/upload/lakbay/destinations/1/beach.jpg"


class FakeStorageClient:
    def __init__(self) -> None:
        self.calls: list[dict] = []

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


def _use_fake_storage(client) -> FakeStorageClient:
    storage = FakeStorageClient()
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

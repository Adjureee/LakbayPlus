from app.integrations.storage.client import StorageUploadResult, get_storage_client


JPEG_BYTES = b"\xff\xd8\xff\xe0avatar-image"


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
            image_url="https://res.cloudinary.com/demo/image/upload/avatar.jpg",
            cloudinary_public_id="lakbay/users/7/profile/avatar",
            original_filename=filename,
            content_type=content_type,
            bytes=len(file_bytes),
            format="jpg",
            resource_type="image",
        )


def register_user(client) -> dict[str, str]:
    response = client.post(
        "/api/v1/auth/register",
        json={
            "full_name": "Profile Photo User",
            "email": "profile-photo@example.com",
            "password": "password123",
            "confirm_password": "password123",
        },
    )
    assert response.status_code == 201
    return {"Authorization": f"Bearer {response.json()['tokens']['access_token']}"}


def test_upload_profile_photo_persists_cloudinary_url(client) -> None:
    headers = register_user(client)
    storage = FakeStorageClient()
    client.app.dependency_overrides[get_storage_client] = lambda: storage

    response = client.post(
        "/api/v1/users/me/avatar",
        headers=headers,
        files={"file": ("avatar.jpg", JPEG_BYTES, "image/jpeg")},
    )

    assert response.status_code == 200
    assert response.json()["avatar_url"] == (
        "https://res.cloudinary.com/demo/image/upload/avatar.jpg"
    )
    assert storage.calls == [
        {
            "file_bytes": JPEG_BYTES,
            "filename": "avatar.jpg",
            "content_type": "image/jpeg",
            "folder_suffix": "users/1/profile",
        }
    ]

    current_user = client.get("/api/v1/users/me", headers=headers)
    assert current_user.status_code == 200
    assert current_user.json()["avatar_url"] == response.json()["avatar_url"]


def test_profile_photo_upload_requires_authentication(client) -> None:
    response = client.post(
        "/api/v1/users/me/avatar",
        files={"file": ("avatar.jpg", JPEG_BYTES, "image/jpeg")},
    )

    assert response.status_code == 401
    assert response.json()["error"]["code"] == "not_authenticated"


def test_profile_photo_upload_rejects_invalid_image(client) -> None:
    headers = register_user(client)
    storage = FakeStorageClient()
    client.app.dependency_overrides[get_storage_client] = lambda: storage

    response = client.post(
        "/api/v1/users/me/avatar",
        headers=headers,
        files={"file": ("avatar.txt", b"not-an-image", "text/plain")},
    )

    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_image_type"
    assert storage.calls == []


def test_upload_cover_saves_url_and_is_separate_from_the_avatar(client) -> None:
    headers = register_user(client)
    storage = FakeStorageClient()
    client.app.dependency_overrides[get_storage_client] = lambda: storage

    before = client.get("/api/v1/users/me", headers=headers).json()
    assert before["cover_url"] is None

    response = client.post(
        "/api/v1/users/me/cover",
        headers=headers,
        files={"file": ("cover.jpg", JPEG_BYTES, "image/jpeg")},
    )

    assert response.status_code == 200
    body = response.json()
    assert body["cover_url"] == "https://res.cloudinary.com/demo/image/upload/avatar.jpg"
    assert body["avatar_url"] is None  # the profile photo is untouched
    assert storage.calls[0]["folder_suffix"] == "users/1/cover"
    assert client.get("/api/v1/users/me", headers=headers).json()["cover_url"] == body["cover_url"]


def test_remove_cover_goes_back_to_the_default(client) -> None:
    headers = register_user(client)
    client.app.dependency_overrides[get_storage_client] = lambda: FakeStorageClient()
    client.post(
        "/api/v1/users/me/cover",
        headers=headers,
        files={"file": ("cover.jpg", JPEG_BYTES, "image/jpeg")},
    )

    response = client.delete("/api/v1/users/me/cover", headers=headers)

    assert response.status_code == 200
    assert response.json()["cover_url"] is None


def test_cover_upload_needs_sign_in_and_a_real_image(client) -> None:
    storage = FakeStorageClient()
    client.app.dependency_overrides[get_storage_client] = lambda: storage
    assert client.post(
        "/api/v1/users/me/cover",
        files={"file": ("cover.jpg", JPEG_BYTES, "image/jpeg")},
    ).status_code == 401

    headers = register_user(client)
    bad = client.post(
        "/api/v1/users/me/cover",
        headers=headers,
        files={"file": ("notes.txt", b"hello", "text/plain")},
    )
    assert bad.status_code >= 400
    assert storage.calls == []

import asyncio
import logging
from types import SimpleNamespace

import pytest

from app.core.exceptions import LakbayAPIError
from app.integrations.storage.client import CloudinaryStorageClient

SECRET = "super-secret-value-123"


def _client() -> CloudinaryStorageClient:
    settings = SimpleNamespace(
        cloudinary_cloud_name="demo-cloud",
        cloudinary_api_key="12345",
        cloudinary_api_secret=SECRET,
        cloudinary_upload_folder="lakbay",
    )
    return CloudinaryStorageClient(settings)  # type: ignore[arg-type]


def test_a_failed_upload_logs_the_real_reason_and_keeps_the_short_message(
    monkeypatch, caplog,
) -> None:
    import cloudinary.uploader

    def boom(*args, **kwargs):
        raise RuntimeError("Upload limit reached for this account")

    monkeypatch.setattr(cloudinary.uploader, "upload", boom)

    with caplog.at_level(logging.ERROR, logger="app.integrations.storage.client"):
        with pytest.raises(LakbayAPIError) as raised:
            asyncio.run(
                _client().upload_image(
                    file_bytes=b"\xff\xd8\xffdata",
                    filename="cover.jpg",
                    content_type="image/jpeg",
                    folder_suffix="users/1/cover",
                )
            )

    # What the traveler sees does not change.
    assert raised.value.message == "Image upload failed."
    assert raised.value.code == "storage_upload_failed"
    # The server log says why, with where it was going, and no secrets.
    log = caplog.text
    assert "RuntimeError" in log
    assert "Upload limit reached for this account" in log
    assert "lakbay/users/1/cover" in log
    assert SECRET not in log


def test_a_failed_delete_is_logged_too(monkeypatch, caplog) -> None:
    import cloudinary.uploader

    def boom(*args, **kwargs):
        raise RuntimeError("Invalid credentials")

    monkeypatch.setattr(cloudinary.uploader, "destroy", boom)

    with caplog.at_level(logging.ERROR, logger="app.integrations.storage.client"):
        with pytest.raises(LakbayAPIError) as raised:
            asyncio.run(_client().delete_image("lakbay/users/1/cover/abc"))

    assert raised.value.code == "storage_delete_failed"
    assert "Invalid credentials" in caplog.text
    assert SECRET not in caplog.text

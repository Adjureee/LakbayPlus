import logging
from dataclasses import dataclass
from io import BytesIO
from typing import Literal

from fastapi import status
from starlette.concurrency import run_in_threadpool

from app.core.config import Settings, get_settings
from app.core.exceptions import LakbayAPIError

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class StorageUploadResult:
    image_url: str
    cloudinary_public_id: str | None
    original_filename: str | None
    content_type: str
    bytes: int
    width: int | None = None
    height: int | None = None
    format: str | None = None
    resource_type: str | None = None
    duration: float | None = None


class CloudinaryStorageClient:
    def __init__(self, settings: Settings | None = None) -> None:
        self.settings = settings or get_settings()

    async def upload_image(
        self,
        *,
        file_bytes: bytes,
        filename: str | None,
        content_type: str,
        folder_suffix: str | None = None,
    ) -> StorageUploadResult:
        self._require_configured()

        try:
            import cloudinary
            import cloudinary.uploader
        except ImportError as exc:
            raise LakbayAPIError(
                "Cloudinary support is not installed.",
                code="storage_dependency_missing",
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            ) from exc

        cloudinary.config(
            cloud_name=self.settings.cloudinary_cloud_name,
            api_key=self.settings.cloudinary_api_key,
            api_secret=self.settings.cloudinary_api_secret,
            secure=True,
        )
        upload_file = BytesIO(file_bytes)
        upload_file.name = filename or "lakbay-upload"
        folder = self._folder(folder_suffix)

        try:
            result = await run_in_threadpool(
                cloudinary.uploader.upload,
                upload_file,
                folder=folder,
                resource_type="image",
                use_filename=True,
                unique_filename=True,
                overwrite=False,
            )
        except Exception as exc:
            # The traveler only sees a short message; the real reason (quota, bad key,
            # network) goes to the server log. No keys or secrets are logged.
            logger.error(
                "Cloudinary upload failed (folder=%s, bytes=%d, content_type=%s): %s: %s",
                folder,
                len(file_bytes),
                content_type,
                type(exc).__name__,
                str(exc)[:300],
            )
            raise LakbayAPIError(
                "Image upload failed.",
                code="storage_upload_failed",
                status_code=status.HTTP_502_BAD_GATEWAY,
            ) from exc

        image_url = result.get("secure_url") or result.get("url")

        if not image_url:
            raise LakbayAPIError(
                "Image upload did not return a URL.",
                code="storage_upload_invalid_response",
                status_code=status.HTTP_502_BAD_GATEWAY,
            )

        return StorageUploadResult(
            image_url=image_url,
            cloudinary_public_id=result.get("public_id"),
            original_filename=filename,
            content_type=content_type,
            bytes=int(result.get("bytes") or len(file_bytes)),
            width=result.get("width"),
            height=result.get("height"),
            format=result.get("format"),
            resource_type=result.get("resource_type"),
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
        self._require_configured()

        try:
            import cloudinary
            import cloudinary.uploader
        except ImportError as exc:
            raise LakbayAPIError(
                "Cloudinary support is not installed.",
                code="storage_dependency_missing",
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            ) from exc

        cloudinary.config(
            cloud_name=self.settings.cloudinary_cloud_name,
            api_key=self.settings.cloudinary_api_key,
            api_secret=self.settings.cloudinary_api_secret,
            secure=True,
        )
        upload_file = BytesIO(file_bytes)
        upload_file.name = filename or "lakbay-upload"
        folder = self._folder(folder_suffix)
        upload_kwargs: dict[str, object] = {
            "folder": folder,
            "resource_type": resource_type,
            "use_filename": True,
            "unique_filename": True,
            "overwrite": False,
        }
        if resource_type == "video":
            upload_kwargs["transformation"] = {
                "width": 1080,
                "crop": "limit",
                "quality": "auto",
            }
        elif content_type != "image/gif":
            # Preserve animated GIF frames; optimize static images cleanly.
            upload_kwargs["transformation"] = {"quality": "auto"}

        try:
            result = await run_in_threadpool(
                cloudinary.uploader.upload,
                upload_file,
                **upload_kwargs,
            )
        except Exception as exc:
            logger.error(
                "Cloudinary media upload failed (folder=%s, bytes=%d, content_type=%s, resource_type=%s): %s: %s",
                folder,
                len(file_bytes),
                content_type,
                resource_type,
                type(exc).__name__,
                str(exc)[:300],
            )
            raise LakbayAPIError(
                "Media upload failed.",
                code="storage_upload_failed",
                status_code=status.HTTP_502_BAD_GATEWAY,
            ) from exc

        media_url = result.get("secure_url") or result.get("url")

        if not media_url:
            raise LakbayAPIError(
                "Media upload did not return a URL.",
                code="storage_upload_invalid_response",
                status_code=status.HTTP_502_BAD_GATEWAY,
            )

        raw_duration = result.get("duration")
        duration = float(raw_duration) if raw_duration is not None else None

        return StorageUploadResult(
            image_url=media_url,
            cloudinary_public_id=result.get("public_id"),
            original_filename=filename,
            content_type=content_type,
            bytes=int(result.get("bytes") or len(file_bytes)),
            width=result.get("width"),
            height=result.get("height"),
            format=result.get("format"),
            resource_type=result.get("resource_type"),
            duration=duration,
        )

    async def delete_image(self, public_id: str) -> str:
        """Destroy one image asset after the caller has checked its ownership."""
        return await self.delete_media(public_id, resource_type="image")

    async def delete_media(
        self,
        public_id: str,
        *,
        resource_type: Literal["image", "video"] = "image",
    ) -> str:
        """Destroy one image or video asset after the caller has checked ownership."""
        self._require_configured()
        try:
            import cloudinary
            import cloudinary.uploader
        except ImportError as exc:
            raise LakbayAPIError(
                "Cloudinary support is not installed.",
                code="storage_dependency_missing",
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            ) from exc

        cloudinary.config(
            cloud_name=self.settings.cloudinary_cloud_name,
            api_key=self.settings.cloudinary_api_key,
            api_secret=self.settings.cloudinary_api_secret,
            secure=True,
        )
        try:
            result = await run_in_threadpool(
                cloudinary.uploader.destroy,
                public_id,
                resource_type=resource_type,
                invalidate=True,
            )
        except Exception as exc:
            logger.error(
                "Cloudinary delete failed (public_id=%s, resource_type=%s): %s: %s",
                public_id,
                resource_type,
                type(exc).__name__,
                str(exc)[:300],
            )
            raise LakbayAPIError(
                "Cloudinary media deletion failed.",
                code="storage_delete_failed",
                status_code=status.HTTP_502_BAD_GATEWAY,
            ) from exc
        outcome = result.get("result") if isinstance(result, dict) else None
        if outcome not in {"ok", "not found"}:
            raise LakbayAPIError(
                "Cloudinary deletion returned an unexpected result.",
                code="storage_delete_invalid_response",
                status_code=status.HTTP_502_BAD_GATEWAY,
            )
        return outcome

    def _require_configured(self) -> None:
        missing = [
            name
            for name, value in (
                ("CLOUDINARY_CLOUD_NAME", self.settings.cloudinary_cloud_name),
                ("CLOUDINARY_API_KEY", self.settings.cloudinary_api_key),
                ("CLOUDINARY_API_SECRET", self.settings.cloudinary_api_secret),
            )
            if not value
        ]

        if missing:
            raise LakbayAPIError(
                "Cloudinary storage is not configured.",
                code="storage_not_configured",
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                details={"missing": missing},
            )

    def _folder(self, folder_suffix: str | None) -> str:
        base_folder = self.settings.cloudinary_upload_folder.strip("/") or "lakbay"

        if not folder_suffix:
            return base_folder

        return f"{base_folder}/{folder_suffix.strip('/')}"


def get_storage_client() -> CloudinaryStorageClient:
    return CloudinaryStorageClient()

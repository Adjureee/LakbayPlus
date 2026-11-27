from dataclasses import dataclass
import struct
from typing import Literal

from fastapi import UploadFile, status

from app.core.config import Settings
from app.core.exceptions import LakbayAPIError
from app.core.provider_usage import ProviderLimiter


_IMAGE_READ_CHUNK_SIZE = 64 * 1024
cloudinary_upload_limiter = ProviderLimiter()

MEDIA_MAX_IMAGE_BYTES = 10 * 1024 * 1024  # 10 MB for JPEG/PNG/WebP/GIF
MEDIA_MAX_VIDEO_BYTES = 15 * 1024 * 1024  # 15 MB for MP4/WebM
MEDIA_MAX_DURATION_SECONDS = 15.0

ALLOWED_MEDIA_IMAGE_TYPES = frozenset(
    {"image/jpeg", "image/png", "image/webp", "image/gif"}
)
ALLOWED_MEDIA_VIDEO_TYPES = frozenset({"video/mp4", "video/webm"})
ALLOWED_MEDIA_TYPES = ALLOWED_MEDIA_IMAGE_TYPES | ALLOWED_MEDIA_VIDEO_TYPES


@dataclass(frozen=True)
class ValidatedMedia:
    file_bytes: bytes
    content_type: str
    media_type: Literal["image", "gif", "video"]
    resource_type: Literal["image", "video"]
    duration_seconds: float | None = None


async def read_validated_image(file: UploadFile, settings: Settings) -> bytes:
    content_type = (file.content_type or "").lower().strip()
    if content_type in {"image/jpg", "image/pjpeg"}:
        content_type = "image/jpeg"
    sniff_from_bytes = content_type in {"", "application/octet-stream", "binary/octet-stream"}

    if not sniff_from_bytes and content_type not in settings.allowed_image_types:
        raise LakbayAPIError(
            "Only JPEG, PNG, or WebP images are allowed.",
            code="invalid_image_type",
            status_code=status.HTTP_400_BAD_REQUEST,
            details={"content_type": file.content_type},
        )

    chunks: list[bytes] = []
    total_bytes = 0

    while chunk := await file.read(_IMAGE_READ_CHUNK_SIZE):
        total_bytes += len(chunk)
        if total_bytes > settings.upload_max_image_bytes:
            raise LakbayAPIError(
                "Uploaded image is too large.",
                code="upload_too_large",
                status_code=status.HTTP_400_BAD_REQUEST,
                details={
                    "max_bytes": settings.upload_max_image_bytes,
                    "actual_bytes": total_bytes,
                },
            )
        chunks.append(chunk)

    file_bytes = b"".join(chunks)
    if not file_bytes:
        raise LakbayAPIError(
            "Uploaded image cannot be empty.",
            code="empty_upload",
            status_code=status.HTTP_400_BAD_REQUEST,
        )

    detected_content_type = detect_image_content_type(file_bytes)
    if detected_content_type is None:
        raise LakbayAPIError(
            "Uploaded file content is not a supported image.",
            code="invalid_image_content",
            status_code=status.HTTP_400_BAD_REQUEST,
            details={"content_type": file.content_type},
        )

    if sniff_from_bytes:
        if detected_content_type not in settings.allowed_image_types:
            raise LakbayAPIError(
                "Only JPEG, PNG, or WebP images are allowed.",
                code="invalid_image_type",
                status_code=status.HTTP_400_BAD_REQUEST,
                details={"content_type": file.content_type},
            )
    elif detected_content_type != content_type:
        raise LakbayAPIError(
            "Uploaded file content does not match its declared image type.",
            code="image_type_mismatch",
            status_code=status.HTTP_400_BAD_REQUEST,
            details={
                "declared_content_type": content_type,
                "detected_content_type": detected_content_type,
            },
        )

    return file_bytes


def reserve_cloudinary_upload(*, user_id: int, settings: Settings) -> None:
    cloudinary_upload_limiter.reserve_many(
        [
            (f"cloudinary:user:{user_id}", settings.cloudinary_uploads_per_user_day, 86400, 1),
            ("cloudinary:all", settings.cloudinary_uploads_per_app_day, 86400, 1),
        ],
        code="cloudinary_upload_rate_limit_exceeded",
        message="Photo upload limit reached. Please try again later.",
    )


def detect_image_content_type(file_bytes: bytes) -> str | None:
    if file_bytes.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if file_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if (
        len(file_bytes) >= 12
        and file_bytes.startswith(b"RIFF")
        and file_bytes[8:12] == b"WEBP"
    ):
        return "image/webp"
    return None


def detect_media_content_type(file_bytes: bytes) -> str | None:
    image_type = detect_image_content_type(file_bytes)
    if image_type is not None:
        return image_type
    if file_bytes.startswith((b"GIF87a", b"GIF89a")):
        return "image/gif"
    if len(file_bytes) >= 12 and file_bytes[4:8] == b"ftyp":
        return "video/mp4"
    if file_bytes.startswith(b"\x1a\x45\xdf\xa3"):
        return "video/webm"
    return None


def extract_video_duration_seconds(file_bytes: bytes, content_type: str) -> float | None:
    """Best-effort pure-Python container duration probe for MP4 and WebM."""
    if content_type == "video/mp4":
        return _extract_mp4_duration_seconds(file_bytes)
    if content_type == "video/webm":
        return _extract_webm_duration_seconds(file_bytes)
    return None


def _iter_mp4_boxes(data: bytes, start: int, end: int):
    offset = start
    while offset + 8 <= end:
        size = struct.unpack(">I", data[offset : offset + 4])[0]
        box_type = data[offset + 4 : offset + 8]
        header_len = 8
        if size == 1:
            if offset + 16 > end:
                break
            size = struct.unpack(">Q", data[offset + 8 : offset + 16])[0]
            header_len = 16
        elif size == 0:
            size = end - offset
        if size < header_len:
            break
        box_end = min(offset + size, end)
        yield box_type, offset + header_len, box_end
        offset = box_end


def _extract_mp4_duration_seconds(data: bytes) -> float | None:
    try:
        length = len(data)
        for box_type, payload_start, box_end in _iter_mp4_boxes(data, 0, length):
            if box_type != b"moov":
                continue
            for child_type, child_start, child_end in _iter_mp4_boxes(
                data, payload_start, box_end
            ):
                if child_type != b"mvhd":
                    continue
                payload = data[child_start:child_end]
                if not payload:
                    return None
                version = payload[0]
                if version == 0 and len(payload) >= 20:
                    timescale, duration = struct.unpack(">II", payload[12:20])
                elif version == 1 and len(payload) >= 32:
                    timescale = struct.unpack(">I", payload[20:24])[0]
                    duration = struct.unpack(">Q", payload[24:32])[0]
                else:
                    return None
                if timescale > 0:
                    return duration / timescale
                return None
    except (struct.error, IndexError):
        return None
    return None


def _read_ebml_id(data: bytes, pos: int) -> tuple[int, int] | None:
    if pos >= len(data):
        return None
    first = data[pos]
    for width in range(1, 5):
        mask = 0x80 >> (width - 1)
        if first & mask:
            if pos + width > len(data):
                return None
            return int.from_bytes(data[pos : pos + width], "big"), pos + width
    return None


def _read_ebml_size(data: bytes, pos: int) -> tuple[int | None, int] | None:
    if pos >= len(data):
        return None
    first = data[pos]
    for width in range(1, 9):
        mask = 0x80 >> (width - 1)
        if first & mask:
            if pos + width > len(data):
                return None
            val = first & (mask - 1)
            for b in data[pos + 1 : pos + width]:
                val = (val << 8) | b
            unknown_marker = (1 << (7 * width)) - 1
            if val == unknown_marker:
                return None, pos + width
            return val, pos + width
    return None


def _extract_webm_duration_seconds(data: bytes) -> float | None:
    try:
        pos = 0
        length = len(data)
        seg_start = None
        seg_end = length
        while pos < length:
            id_res = _read_ebml_id(data, pos)
            if id_res is None:
                return None
            elem_id, next_pos = id_res
            size_res = _read_ebml_size(data, next_pos)
            if size_res is None:
                return None
            elem_size, payload_start = size_res
            if elem_id == 0x18538067:  # Segment
                seg_start = payload_start
                seg_end = length if elem_size is None else min(payload_start + elem_size, length)
                break
            if elem_size is None:
                return None
            pos = payload_start + elem_size

        if seg_start is None:
            return None

        pos = seg_start
        while pos < seg_end:
            id_res = _read_ebml_id(data, pos)
            if id_res is None:
                return None
            elem_id, next_pos = id_res
            size_res = _read_ebml_size(data, next_pos)
            if size_res is None:
                return None
            elem_size, payload_start = size_res
            if elem_id == 0x1549A966:  # Info
                info_end = seg_end if elem_size is None else min(payload_start + elem_size, seg_end)
                timecode_scale = 1_000_000
                duration_val: float | None = None
                ipos = payload_start
                while ipos < info_end:
                    i_id_res = _read_ebml_id(data, ipos)
                    if i_id_res is None:
                        break
                    i_id, i_next = i_id_res
                    i_size_res = _read_ebml_size(data, i_next)
                    if i_size_res is None:
                        break
                    i_size, i_payload = i_size_res
                    if i_size is None or i_payload + i_size > info_end:
                        break
                    chunk = data[i_payload : i_payload + i_size]
                    if i_id == 0x2AD7B1 and 1 <= len(chunk) <= 8:  # TimecodeScale
                        timecode_scale = int.from_bytes(chunk, "big")
                    elif i_id == 0x4489:  # Duration
                        if len(chunk) == 4:
                            duration_val = struct.unpack(">f", chunk)[0]
                        elif len(chunk) == 8:
                            duration_val = struct.unpack(">d", chunk)[0]
                    ipos = i_payload + i_size
                if duration_val is not None and timecode_scale > 0:
                    return (duration_val * timecode_scale) / 1_000_000_000.0
                return None
            if elem_id == 0x1F43B675 or elem_size is None:  # Cluster or unknown size
                break
            pos = payload_start + elem_size
    except (struct.error, IndexError, ValueError):
        return None
    return None


async def read_validated_media(file: UploadFile) -> ValidatedMedia:
    raw_content_type = (file.content_type or "").split(";", 1)[0].lower().strip()
    if raw_content_type in {"image/jpg", "image/pjpeg"}:
        content_type = "image/jpeg"
    else:
        content_type = raw_content_type

    sniff_from_bytes = content_type in {
        "",
        "application/octet-stream",
        "binary/octet-stream",
    }

    if not sniff_from_bytes and content_type not in ALLOWED_MEDIA_TYPES:
        raise LakbayAPIError(
            "Only JPEG, PNG, WebP, GIF, MP4, or WebM files are allowed.",
            code="invalid_media_type",
            status_code=status.HTTP_400_BAD_REQUEST,
            details={"content_type": file.content_type},
        )

    stream_limit = (
        MEDIA_MAX_IMAGE_BYTES
        if (not sniff_from_bytes and content_type in ALLOWED_MEDIA_IMAGE_TYPES)
        else MEDIA_MAX_VIDEO_BYTES
    )

    chunks: list[bytes] = []
    total_bytes = 0

    while chunk := await file.read(_IMAGE_READ_CHUNK_SIZE):
        total_bytes += len(chunk)
        if total_bytes > stream_limit:
            raise LakbayAPIError(
                "Uploaded media file is too large.",
                code="upload_too_large",
                status_code=status.HTTP_400_BAD_REQUEST,
                details={
                    "max_bytes": stream_limit,
                    "actual_bytes": total_bytes,
                },
            )
        chunks.append(chunk)

    file_bytes = b"".join(chunks)
    if not file_bytes:
        raise LakbayAPIError(
            "Uploaded media file cannot be empty.",
            code="empty_upload",
            status_code=status.HTTP_400_BAD_REQUEST,
        )

    detected_content_type = detect_media_content_type(file_bytes)
    if detected_content_type is None:
        raise LakbayAPIError(
            "Uploaded file content is not a supported image, GIF, or video clip.",
            code="invalid_media_content",
            status_code=status.HTTP_400_BAD_REQUEST,
            details={"content_type": file.content_type},
        )

    if not sniff_from_bytes and detected_content_type != content_type:
        raise LakbayAPIError(
            "Uploaded file content does not match its declared media type.",
            code="media_type_mismatch",
            status_code=status.HTTP_400_BAD_REQUEST,
            details={
                "declared_content_type": content_type,
                "detected_content_type": detected_content_type,
            },
        )

    if (
        detected_content_type in ALLOWED_MEDIA_IMAGE_TYPES
        and len(file_bytes) > MEDIA_MAX_IMAGE_BYTES
    ):
        raise LakbayAPIError(
            "Uploaded image or GIF exceeds the 10 MB limit.",
            code="upload_too_large",
            status_code=status.HTTP_400_BAD_REQUEST,
            details={
                "max_bytes": MEDIA_MAX_IMAGE_BYTES,
                "actual_bytes": len(file_bytes),
            },
        )

    if detected_content_type == "image/gif":
        media_type: Literal["image", "gif", "video"] = "gif"
        resource_type: Literal["image", "video"] = "image"
    elif detected_content_type in ALLOWED_MEDIA_VIDEO_TYPES:
        media_type = "video"
        resource_type = "video"
    else:
        media_type = "image"
        resource_type = "image"

    duration_seconds: float | None = None
    if media_type == "video":
        duration_seconds = extract_video_duration_seconds(
            file_bytes, detected_content_type
        )
        if (
            duration_seconds is not None
            and duration_seconds > MEDIA_MAX_DURATION_SECONDS
        ):
            raise LakbayAPIError(
                "Video clips must be 15 seconds or shorter.",
                code="media_duration_exceeded",
                status_code=status.HTTP_400_BAD_REQUEST,
                details={
                    "max_duration_seconds": MEDIA_MAX_DURATION_SECONDS,
                    "actual_duration_seconds": round(duration_seconds, 2),
                },
            )

    return ValidatedMedia(
        file_bytes=file_bytes,
        content_type=detected_content_type,
        media_type=media_type,
        resource_type=resource_type,
        duration_seconds=duration_seconds,
    )

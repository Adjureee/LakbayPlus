import logging
from posixpath import splitext
from time import monotonic
from urllib.parse import urlsplit, urlunsplit

from fastapi import UploadFile, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings, get_settings
from app.integrations.storage.client import CloudinaryStorageClient
from app.integrations.storage.uploads import (
    MEDIA_MAX_DURATION_SECONDS,
    read_validated_image,
    read_validated_media,
    reserve_cloudinary_upload,
)

from app.features.destinations.region import island_group_for
from app.core.exceptions import LakbayAPIError
from app.features.destinations.data_quality import data_quality as hours_data_quality
from app.features.destinations.hours import hours_summary
from app.features.destinations.activities import activity_summary
from app.features.destinations.prices import prices_summary
from app.features.destinations.repository import DestinationRepository
from app.features.recommendations.preference_groups import load_groups
from app.features.destinations.schemas import (
    DestinationFacetsResponse,
    ActivityOut,
    DestinationActivitiesResponse,
    DestinationActivitiesUpdate,
    DestinationCreate,
    DestinationHoursResponse,
    DestinationHoursUpdate,
    DestinationListQuery,
    DestinationPricesResponse,
    DestinationPricesUpdate,
    DestinationResponse,
    DestinationUpdate,
    HoursExceptionIn,
    HoursWindowIn,
    PriceIn,
)

FACETS_CACHE_TTL_SECONDS = 60.0
_facets_cache: tuple[float, DestinationFacetsResponse] | None = None
logger = logging.getLogger(__name__)


def _cloudinary_video_poster_url(url: str | None) -> str | None:
    if not url:
        return None
    parsed = urlsplit(url)
    if parsed.netloc != "res.cloudinary.com" or "/video/upload/" not in parsed.path:
        return None
    prefix, rest = parsed.path.split("/video/upload/", 1)
    if not rest:
        return None
    stem, _ = splitext(rest)
    poster_path = f"{prefix}/video/upload/so_0,f_jpg,q_auto/{stem}.jpg"
    return urlunsplit((parsed.scheme, parsed.netloc, poster_path, "", ""))


def _cloudinary_gif_poster_url(url: str | None) -> str | None:
    if not url:
        return None
    parsed = urlsplit(url)
    if parsed.netloc != "res.cloudinary.com" or "/image/upload/" not in parsed.path:
        return url
    prefix, rest = parsed.path.split("/image/upload/", 1)
    if not rest:
        return url
    stem, _ = splitext(rest)
    poster_path = f"{prefix}/image/upload/pg_1,f_jpg,q_auto/{stem}.jpg"
    return urlunsplit((parsed.scheme, parsed.netloc, poster_path, "", ""))


def clear_facets_cache() -> None:
    """Clear the cached /destinations/facets response."""
    global _facets_cache
    _facets_cache = None


class DestinationService:
    def __init__(
        self,
        session: AsyncSession,
        *,
        storage_client: CloudinaryStorageClient | None = None,
        settings: Settings | None = None,
    ) -> None:
        self.session = session
        self.destinations = DestinationRepository(session)
        self.storage_client = storage_client
        self.settings = settings or get_settings()

    async def upload_photo(
        self,
        destination_id: int,
        *,
        file: UploadFile,
        admin_user_id: int,
    ) -> DestinationResponse:
        """Upload a new destination photo to Cloudinary and use it as image_url.

        The previous image is left in Cloudinary: the traveler app's bundled
        catalog may still point at it until the next export.
        """
        destination = await self.destinations.get_by_id(
            destination_id,
            include_inactive=True,
        )
        if destination is None:
            raise LakbayAPIError(
                "Destination was not found.",
                code="destination_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
            )
        file_bytes = await read_validated_image(file, self.settings)
        reserve_cloudinary_upload(user_id=admin_user_id, settings=self.settings)
        storage = self.storage_client or CloudinaryStorageClient(self.settings)
        result = await storage.upload_image(
            file_bytes=file_bytes,
            filename=file.filename,
            content_type=(file.content_type or "").lower(),
            folder_suffix=f"destinations/{destination_id}",
        )
        updated = await self.destinations.update(
            destination,
            {
                "image_url": result.image_url,
                "image_public_id": result.cloudinary_public_id,
            },
        )
        await self.session.commit()
        await self.session.refresh(updated)
        clear_facets_cache()
        return DestinationResponse.model_validate(updated)

    async def upload_media(
        self,
        destination_id: int,
        *,
        file: UploadFile,
        admin_user_id: int,
    ) -> DestinationResponse:
        """Upload a photo, animated GIF, or <=15s MP4/WebM clip for a destination."""
        destination = await self.destinations.get_by_id(
            destination_id,
            include_inactive=True,
        )
        if destination is None:
            raise LakbayAPIError(
                "Destination was not found.",
                code="destination_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        validated = await read_validated_media(file)
        reserve_cloudinary_upload(user_id=admin_user_id, settings=self.settings)
        storage = self.storage_client or CloudinaryStorageClient(self.settings)
        result = await storage.upload_media(
            file_bytes=validated.file_bytes,
            filename=file.filename,
            content_type=validated.content_type,
            resource_type=validated.resource_type,
            folder_suffix=f"destinations/{destination_id}",
        )

        duration = (
            result.duration
            if result.duration is not None
            else validated.duration_seconds
        )
        if (
            validated.media_type == "video"
            and duration is not None
            and duration > MEDIA_MAX_DURATION_SECONDS
        ):
            if result.cloudinary_public_id:
                try:
                    await storage.delete_media(
                        result.cloudinary_public_id,
                        resource_type="video",
                    )
                except Exception as exc:
                    logger.warning(
                        "Failed to clean up over-duration Cloudinary video %s: %s",
                        result.cloudinary_public_id,
                        exc,
                    )
            raise LakbayAPIError(
                "Video clips must be 15 seconds or shorter.",
                code="media_duration_exceeded",
                status_code=status.HTTP_400_BAD_REQUEST,
                details={
                    "max_duration_seconds": MEDIA_MAX_DURATION_SECONDS,
                    "actual_duration_seconds": round(duration, 2),
                },
            )

        updates: dict[str, object] = {
            "media_url": result.image_url,
            "media_type": validated.media_type,
            "media_public_id": result.cloudinary_public_id,
            "media_duration_seconds": (
                round(duration, 2)
                if (validated.media_type == "video" and duration is not None)
                else None
            ),
        }

        existing_poster = (destination.image_url or "").strip()
        if validated.media_type == "image":
            updates["image_url"] = result.image_url
            updates["image_public_id"] = result.cloudinary_public_id
        elif validated.media_type == "gif":
            if not existing_poster:
                poster = _cloudinary_gif_poster_url(result.image_url)
                if poster:
                    updates["image_url"] = poster
        elif validated.media_type == "video":
            if not existing_poster:
                poster = _cloudinary_video_poster_url(result.image_url)
                if poster:
                    updates["image_url"] = poster

        updated = await self.destinations.update(destination, updates)
        await self.session.commit()
        await self.session.refresh(updated)
        clear_facets_cache()
        return DestinationResponse.model_validate(updated)

    async def facets(self) -> DestinationFacetsResponse:
        """Preference groups and normalized live categories with counts (cached 60s)."""
        global _facets_cache
        now = monotonic()
        if _facets_cache is not None and (now - _facets_cache[0]) < FACETS_CACHE_TTL_SECONDS:
            return _facets_cache[1]
        places: list[DestinationResponse] = []
        offset = 0
        while True:
            page = await self.list_destinations(DestinationListQuery(limit=100, offset=offset))
            places.extend(page)
            if len(page) < 100:
                break
            offset += len(page)
        groups_registry = load_groups()
        response = DestinationFacetsResponse(
            total_places=len(places),
            groups=groups_registry.facets(places),
            categories=groups_registry.categories(places),
        )
        _facets_cache = (now, response)
        return response

    async def list_destinations(
        self,
        filters: DestinationListQuery,
    ) -> list[DestinationResponse]:
        destinations = await self.destinations.list(filters)

        return [DestinationResponse.model_validate(item) for item in destinations]

    async def get_destination(
        self,
        destination_id: int,
        *,
        include_inactive: bool = False,
    ) -> DestinationResponse:
        destination = await self.destinations.get_by_id(
            destination_id,
            include_inactive=include_inactive,
        )

        if destination is None:
            raise LakbayAPIError(
                "Destination was not found.",
                code="destination_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        return DestinationResponse.model_validate(destination)

    async def get_hours(self, destination_id: int) -> DestinationHoursResponse:
        destination = await self._active_destination(destination_id)
        weekly, exceptions = await self.destinations.get_hours(destination_id)
        return self._hours_response(destination, weekly, exceptions)

    async def replace_hours(
        self, destination_id: int, data: DestinationHoursUpdate,
    ) -> DestinationHoursResponse:
        destination = await self._active_destination(destination_id)
        await self.destinations.replace_hours(destination, data)
        await self.session.commit()
        weekly, exceptions = await self.destinations.get_hours(destination_id)
        return self._hours_response(destination, weekly, exceptions)

    async def get_prices(self, destination_id: int) -> DestinationPricesResponse:
        destination = await self._active_destination(destination_id)
        prices = await self.destinations.get_prices(destination_id)
        return self._prices_response(destination, prices)

    async def replace_prices(
        self, destination_id: int, data: DestinationPricesUpdate,
    ) -> DestinationPricesResponse:
        destination = await self._active_destination(destination_id)
        await self.destinations.replace_prices(destination, data)
        await self.session.commit()
        prices = await self.destinations.get_prices(destination_id)
        return self._prices_response(destination, prices)

    @staticmethod
    def _prices_response(destination, prices) -> DestinationPricesResponse:
        return DestinationPricesResponse(
            destination_id=destination.destination_id,
            fees_source_url=destination.fees_source_url,
            fees_verified_at=destination.fees_verified_at,
            prices=[PriceIn.model_validate(r) for r in prices],
            summary=prices_summary(prices),
            data_quality=hours_data_quality(
                bool(prices),
                bool(destination.entrance_fee or destination.overnight_fee),
                destination.fees_verified_at,
            ),
        )

    async def get_activities(self, destination_id: int) -> DestinationActivitiesResponse:
        await self._active_destination(destination_id)
        rows = await self.destinations.get_activities(destination_id)
        return self._activities_response(destination_id, rows)

    async def replace_activities(
        self, destination_id: int, data: DestinationActivitiesUpdate,
    ) -> DestinationActivitiesResponse:
        destination = await self._active_destination(destination_id)
        await self.destinations.replace_activities(destination, data)
        await self.session.commit()
        rows = await self.destinations.get_activities(destination_id)
        return self._activities_response(destination_id, rows)

    @staticmethod
    def _activities_response(destination_id, rows) -> DestinationActivitiesResponse:
        return DestinationActivitiesResponse(
            destination_id=destination_id,
            activities=[
                ActivityOut(
                    **{
                        k: getattr(r, k)
                        for k in ActivityOut.model_fields
                        if k not in {"summary", "data_quality"}
                    },
                    summary=activity_summary(r),
                    data_quality=hours_data_quality(True, False, r.verified_at),
                )
                for r in rows
            ],
        )

    async def _active_destination(self, destination_id: int):
        destination = await self.destinations.get_by_id(destination_id)
        if destination is None:
            raise LakbayAPIError(
                "Destination was not found.",
                code="destination_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
            )
        return destination

    @staticmethod
    def _hours_response(destination, weekly, exceptions) -> DestinationHoursResponse:
        structured = bool(weekly) or bool(destination.open_24_hours)
        return DestinationHoursResponse(
            destination_id=destination.destination_id,
            open_24_hours=destination.open_24_hours,
            hours_source_url=destination.hours_source_url,
            hours_verified_at=destination.hours_verified_at,
            weekly=[HoursWindowIn.model_validate(r) for r in weekly],
            exceptions=[HoursExceptionIn.model_validate(r) for r in exceptions],
            summary=hours_summary(destination.open_24_hours, weekly),
            data_quality=hours_data_quality(
                structured, bool(destination.operating_hours), destination.hours_verified_at,
            ),
        )

    async def create_destination(
        self,
        data: DestinationCreate,
    ) -> DestinationResponse:
        if data.island_group is None:
            # A place on Samal, Talikud, Kopiat, ... must route via a pier.
            data = data.model_copy(update={
                "island_group": island_group_for(data.lat, data.lng),
            })
        destination = await self.destinations.create(data)
        await self.session.commit()
        await self.session.refresh(destination)
        clear_facets_cache()

        return DestinationResponse.model_validate(destination)

    async def update_destination(
        self,
        destination_id: int,
        data: DestinationUpdate,
    ) -> DestinationResponse:
        destination = await self.destinations.get_by_id(
            destination_id,
            include_inactive=True,
        )

        if destination is None:
            raise LakbayAPIError(
                "Destination was not found.",
                code="destination_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        values = data.model_dump(exclude_unset=True)

        if not values:
            raise LakbayAPIError(
                "At least one destination field must be provided.",
                code="empty_destination_update",
                status_code=status.HTTP_400_BAD_REQUEST,
            )

        if "route_ready" in values and values["route_ready"] is None:
            raise LakbayAPIError(
                "route_ready must be true or false.",
                code="invalid_route_ready",
                status_code=status.HTTP_400_BAD_REQUEST,
            )

        arrival_lat = values.get("arrival_lat", destination.arrival_lat)
        arrival_lng = values.get("arrival_lng", destination.arrival_lng)
        arrival_source_url = values.get("arrival_source_url", destination.arrival_source_url)
        arrival_verified_at = values.get("arrival_verified_at", destination.arrival_verified_at)
        route_ready = values.get("route_ready", destination.route_ready)
        if (arrival_lat is None) != (arrival_lng is None):
            raise LakbayAPIError(
                "Arrival latitude and longitude must be provided together.",
                code="invalid_arrival_point",
                status_code=status.HTTP_400_BAD_REQUEST,
            )
        if route_ready and (
            arrival_lat is None
            or not arrival_source_url
            or arrival_verified_at is None
        ):
            raise LakbayAPIError(
                "A route-ready destination needs a sourced, verified arrival point.",
                code="arrival_point_unverified",
                status_code=status.HTTP_400_BAD_REQUEST,
            )
        if route_ready and {"arrival_lat", "arrival_lng"}.intersection(values) and (
            "arrival_source_url" not in values or "arrival_verified_at" not in values
        ):
            raise LakbayAPIError(
                "Reconfirm the source and time when changing a route-ready arrival point.",
                code="arrival_point_reverification_required",
                status_code=status.HTTP_400_BAD_REQUEST,
            )

        updated_destination = await self.destinations.update(destination, values)
        await self.session.commit()
        await self.session.refresh(updated_destination)
        clear_facets_cache()

        return DestinationResponse.model_validate(updated_destination)

    async def deactivate_destination(self, destination_id: int) -> DestinationResponse:
        destination = await self.destinations.get_by_id(
            destination_id,
            include_inactive=True,
        )

        if destination is None:
            raise LakbayAPIError(
                "Destination was not found.",
                code="destination_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
            )

        deactivated_destination = await self.destinations.deactivate(destination)
        await self.session.commit()
        await self.session.refresh(deactivated_destination)
        clear_facets_cache()

        return DestinationResponse.model_validate(deactivated_destination)

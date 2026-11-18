from time import monotonic

from fastapi import UploadFile, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings, get_settings
from app.integrations.storage.client import CloudinaryStorageClient
from app.integrations.storage.uploads import (
    read_validated_image,
    reserve_cloudinary_upload,
)

from app.features.destinations.region import island_group_for
from app.core.exceptions import LakbayAPIError
from app.features.destinations.hours import data_quality as hours_data_quality
from app.features.destinations.hours import hours_summary
from app.features.destinations.repository import DestinationRepository
from app.features.recommendations.preference_groups import load_groups
from app.features.destinations.schemas import (
    DestinationFacetsResponse,
    DestinationCreate,
    DestinationHoursResponse,
    DestinationHoursUpdate,
    DestinationListQuery,
    DestinationResponse,
    DestinationUpdate,
    HoursExceptionIn,
    HoursWindowIn,
)

FACETS_CACHE_TTL_SECONDS = 60.0
_facets_cache: tuple[float, DestinationFacetsResponse] | None = None


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
            {"image_url": result.image_url},
        )
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

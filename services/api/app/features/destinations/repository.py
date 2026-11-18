from geoalchemy2.elements import WKTElement
from sqlalchemy import Select, delete, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.features.destinations.models import (
    Destination,
    DestinationHourException,
    DestinationActivity,
    DestinationHours,
    DestinationPrice,
)
from app.features.destinations.schemas import (
    DestinationActivitiesUpdate,
    DestinationCreate,
    DestinationHoursUpdate,
    DestinationListQuery,
    DestinationPricesUpdate,
)


class DestinationRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def list(self, filters: DestinationListQuery) -> list[Destination]:
        statement = (
            self._apply_filters(select(Destination), filters)
            .order_by(Destination.name.asc(), Destination.destination_id.asc())
            .offset(filters.offset)
            .limit(filters.limit)
        )
        result = await self.session.execute(statement)

        return list(result.scalars().all())

    async def get_by_id(
        self,
        destination_id: int,
        *,
        include_inactive: bool = False,
    ) -> Destination | None:
        statement = select(Destination).where(
            Destination.destination_id == destination_id,
        )

        if not include_inactive:
            statement = statement.where(Destination.is_active.is_(True))

        result = await self.session.execute(statement)

        return result.scalar_one_or_none()

    async def get_hours(
        self, destination_id: int,
    ) -> "tuple[list[DestinationHours], list[DestinationHourException]]":
        weekly = await self.session.execute(
            select(DestinationHours)
            .where(DestinationHours.destination_id == destination_id)
            .order_by(DestinationHours.weekday, DestinationHours.opens_at),
        )
        exceptions = await self.session.execute(
            select(DestinationHourException)
            .where(DestinationHourException.destination_id == destination_id)
            .order_by(DestinationHourException.starts_on),
        )
        return list(weekly.scalars().all()), list(exceptions.scalars().all())

    async def replace_hours(
        self, destination: Destination, data: DestinationHoursUpdate,
    ) -> None:
        """Swap a place's whole schedule for the one given (one transaction)."""
        destination.open_24_hours = data.open_24_hours
        destination.hours_source_url = data.hours_source_url
        destination.hours_verified_at = data.hours_verified_at
        await self.session.execute(
            delete(DestinationHours).where(
                DestinationHours.destination_id == destination.destination_id,
            ),
        )
        await self.session.execute(
            delete(DestinationHourException).where(
                DestinationHourException.destination_id == destination.destination_id,
            ),
        )
        self.session.add_all(
            DestinationHours(destination_id=destination.destination_id, **row.model_dump())
            for row in data.weekly
        )
        self.session.add_all(
            DestinationHourException(
                destination_id=destination.destination_id, **row.model_dump(),
            )
            for row in data.exceptions
        )
        await self.session.flush()

    async def get_prices(self, destination_id: int) -> "list[DestinationPrice]":
        result = await self.session.execute(
            select(DestinationPrice)
            .where(DestinationPrice.destination_id == destination_id)
            .order_by(DestinationPrice.item, DestinationPrice.audience, DestinationPrice.id),
        )
        return list(result.scalars().all())

    async def replace_prices(
        self, destination: Destination, data: DestinationPricesUpdate,
    ) -> None:
        """Swap a place's whole price list for the one given (one transaction)."""
        destination.fees_source_url = data.fees_source_url
        destination.fees_verified_at = data.fees_verified_at
        await self.session.execute(
            delete(DestinationPrice).where(
                DestinationPrice.destination_id == destination.destination_id,
            ),
        )
        self.session.add_all(
            DestinationPrice(destination_id=destination.destination_id, **row.model_dump())
            for row in data.prices
        )
        await self.session.flush()

    async def get_activities(self, destination_id: int) -> "list[DestinationActivity]":
        result = await self.session.execute(
            select(DestinationActivity)
            .where(DestinationActivity.destination_id == destination_id)
            .order_by(DestinationActivity.sort_order, DestinationActivity.id),
        )
        return list(result.scalars().all())

    async def replace_activities(
        self, destination: Destination, data: DestinationActivitiesUpdate,
    ) -> None:
        """Swap a place's whole activity list for the one given (one transaction)."""
        await self.session.execute(
            delete(DestinationActivity).where(
                DestinationActivity.destination_id == destination.destination_id,
            ),
        )
        self.session.add_all(
            DestinationActivity(
                destination_id=destination.destination_id, sort_order=index,
                **row.model_dump(),
            )
            for index, row in enumerate(data.activities)
        )
        await self.session.flush()

    async def create(self, data: DestinationCreate) -> Destination:
        destination_values = data.model_dump()
        geom = self._build_geom(lat=data.lat, lng=data.lng)

        if geom is not None:
            destination_values["geom"] = geom

        destination = Destination(**destination_values)
        self.session.add(destination)
        await self.session.flush()

        return destination

    async def update(
        self,
        destination: Destination,
        values: dict,
    ) -> Destination:
        for field, value in values.items():
            setattr(destination, field, value)

        if "lat" in values or "lng" in values:
            geom = self._build_geom(
                lat=destination.lat,
                lng=destination.lng,
            )

            if geom is not None:
                destination.geom = geom

        await self.session.flush()

        return destination

    async def deactivate(self, destination: Destination) -> Destination:
        destination.is_active = False
        await self.session.flush()

        return destination

    def _apply_filters(
        self,
        statement: Select[tuple[Destination]],
        filters: DestinationListQuery,
    ) -> Select[tuple[Destination]]:
        if not filters.include_inactive:
            statement = statement.where(Destination.is_active.is_(True))

        if filters.search:
            search_pattern = f"%{filters.search.strip()}%"
            statement = statement.where(
                or_(
                    Destination.name.ilike(search_pattern),
                    Destination.description.ilike(search_pattern),
                    Destination.location.ilike(search_pattern),
                    Destination.category.ilike(search_pattern),
                    Destination.activities.ilike(search_pattern),
                )
            )

        if filters.district:
            statement = statement.where(Destination.district.ilike(filters.district))

        if filters.category:
            statement = statement.where(Destination.category.ilike(filters.category))

        if filters.budget_class:
            statement = statement.where(
                Destination.budget_class.ilike(filters.budget_class),
            )

        if filters.difficulty_level:
            statement = statement.where(
                Destination.difficulty_level.ilike(filters.difficulty_level),
            )

        if filters.kid_friendly is not None:
            statement = statement.where(
                Destination.is_kid_friendly.is_(filters.kid_friendly),
            )

        if filters.wheelchair_accessible is not None:
            statement = statement.where(
                Destination.is_wheelchair_accessible.is_(
                    filters.wheelchair_accessible,
                ),
            )

        if filters.pet_friendly is not None:
            statement = statement.where(
                Destination.is_pet_friendly.is_(filters.pet_friendly),
            )

        if filters.family_friendly is not None:
            statement = statement.where(
                Destination.family_friendly.is_(filters.family_friendly),
            )

        if filters.couple_friendly is not None:
            statement = statement.where(
                Destination.couple_friendly.is_(filters.couple_friendly),
            )

        if filters.group_friendly is not None:
            statement = statement.where(
                Destination.group_friendly.is_(filters.group_friendly),
            )

        return statement

    def _build_geom(self, *, lat: float, lng: float) -> WKTElement | None:
        bind = self.session.get_bind()

        if bind.dialect.name != "postgresql":
            return None

        return WKTElement(f"POINT({lng} {lat})", srid=4326)

from sqlalchemy import and_, or_, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.features.users.models import User
from app.features.trips.models import (
    Trip,
    TripDestination,
    TripItineraryDay,
    TripMember,
    TripTimelineRevision,
)


class ReportRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def get_accessible_trip(self, *, user_id: int, trip_id: int) -> Trip | None:
        result = await self.session.execute(
            select(Trip)
            .where(Trip.trip_id == trip_id, _trip_access_filter(user_id))
            .options(
                selectinload(Trip.destinations).selectinload(TripDestination.destination),
                selectinload(Trip.itinerary_days).selectinload(TripItineraryDay.activities),
                selectinload(Trip.route),
                selectinload(Trip.members).selectinload(TripMember.user),
                selectinload(Trip.tasks),
            )
        )

        return result.scalar_one_or_none()


    async def timeline_revisions(
        self, trip_id: int,
    ) -> list[tuple[TripTimelineRevision, str | None]]:
        """Every saved revision of the trip's timeline, oldest first, with the name of who
        saved it (None when that account is gone). At most 50 are kept per trip."""
        result = await self.session.execute(
            select(TripTimelineRevision, User.full_name)
            .outerjoin(User, User.user_id == TripTimelineRevision.created_by_user_id)
            .where(TripTimelineRevision.trip_id == trip_id)
            .order_by(TripTimelineRevision.revision),
        )
        return [(row, name) for row, name in result.all()]


def _trip_access_filter(user_id: int):
    return or_(
        Trip.owner_user_id == user_id,
        Trip.members.any(
            and_(
                TripMember.user_id == user_id,
                TripMember.status == "active",
            )
        ),
    )

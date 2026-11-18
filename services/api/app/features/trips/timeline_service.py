"""Saves and reads a trip's timeline revisions.

Saving needs permission to manage the trip (the owner or an organizer); reading needs
only access to the trip. The timeline is always rebuilt by the server from the state sent,
with the latest saved revision as `previous` so the stored `changes` say what moved.
"""

from fastapi import status
from sqlalchemy import delete, func, select
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.exceptions import LakbayAPIError
from app.features.planning.schemas import PlanningState
from app.features.planning.timeline_schemas import Timeline, TimelineRequest
from app.features.planning.timeline_service import build_timeline_response, describe_changes
from app.features.routes.service import RouteService
from app.features.trips.models import TripTimelineRevision
from app.features.trips.service import TripService
from app.features.trips.timeline_schemas import (
    TripTimelineHistory,
    TripTimelineRevisionResponse,
    TripTimelineRevisionSummary,
    TripTimelineSave,
)
from app.features.users.models import User

# Older revisions beyond this many are removed when a new one is saved.
MAX_REVISIONS = 50


class TripTimelineService:
    def __init__(self, session: AsyncSession, route_service: RouteService | None = None) -> None:
        self.session = session
        self.route_service = route_service
        self.trips = TripService(session)

    async def save(
        self, *, user: User, trip_id: int, data: TripTimelineSave,
    ) -> TripTimelineRevisionResponse:
        await self._require_writable(user=user, trip_id=trip_id)
        latest = await self._latest(trip_id)
        previous = Timeline.model_validate(latest.timeline) if latest else None
        built = await build_timeline_response(
            self.session, self.route_service,
            TimelineRequest(
                state=data.state, pins=data.pins, previous=previous,
                include_meals=data.include_meals,
            ),
        )
        return await self._append(
            user=user, trip_id=trip_id, latest=latest,
            state=data.state.model_dump(mode="json"),
            timeline=built.timeline.model_dump(mode="json"), changes=built.changes,
        )

    async def restore(
        self, *, user: User, trip_id: int, revision: int,
    ) -> TripTimelineRevisionResponse:
        """Saves an older revision again as the newest one, exactly as it was stored.

        Revisions are append-only, so nothing is lost: the old revision stays in the log and
        the newest one is a copy of it. The state and timeline are copied, not rebuilt, so
        the traveler gets back what they had (pins included); `changes` says what moved
        compared with the revision being replaced.
        """
        await self._require_writable(user=user, trip_id=trip_id)
        old = await self._get(trip_id, revision)
        latest = await self._latest(trip_id)
        if latest is not None and latest.revision == old.revision:
            raise LakbayAPIError(
                "That is already the latest revision.",
                code="trip_timeline_already_latest", status_code=status.HTTP_400_BAD_REQUEST,
            )
        moved = describe_changes(
            Timeline.model_validate(latest.timeline), Timeline.model_validate(old.timeline),
        ) if latest is not None else []
        return await self._append(
            user=user, trip_id=trip_id, latest=latest, state=dict(old.state),
            timeline=dict(old.timeline), changes=[f"Restored revision {old.revision}.", *moved],
        )

    async def _require_writable(self, *, user: User, trip_id: int):
        trip = await self.trips._require_trip_manager(user=user, trip_id=trip_id)
        if trip.status == "archived":
            raise LakbayAPIError(
                "Archived trips are read-only for itinerary timelines.",
                code="trip_archived_read_only", status_code=status.HTTP_400_BAD_REQUEST,
            )
        return trip

    async def _append(
        self, *, user: User, trip_id: int, latest: TripTimelineRevision | None,
        state: dict, timeline: dict, changes: list[str],
    ) -> TripTimelineRevisionResponse:
        number = (latest.revision if latest else 0) + 1
        row = TripTimelineRevision(
            trip_id=trip_id, revision=number, state=state, timeline=timeline,
            changes=changes, created_by_user_id=user.user_id,
        )
        self.session.add(row)
        try:
            await self.session.flush()
        except IntegrityError as exc:
            await self.session.rollback()
            raise LakbayAPIError(
                "Another revision was saved at the same time. Try again.",
                code="trip_timeline_conflict", status_code=status.HTTP_409_CONFLICT,
            ) from exc
        await self.session.execute(
            delete(TripTimelineRevision).where(
                TripTimelineRevision.trip_id == trip_id,
                TripTimelineRevision.revision <= number - MAX_REVISIONS,
            ),
        )
        await self.session.commit()
        await self.session.refresh(row)
        return self._full(row)

    async def history(self, *, user: User, trip_id: int) -> TripTimelineHistory:
        await self.trips._require_trip_access(user=user, trip_id=trip_id)
        rows = (await self.session.execute(
            select(TripTimelineRevision)
            .where(TripTimelineRevision.trip_id == trip_id)
            .order_by(TripTimelineRevision.revision.desc()),
        )).scalars().all()
        return TripTimelineHistory(
            latest=self._full(rows[0]) if rows else None,
            revisions=[TripTimelineRevisionSummary.model_validate(r) for r in rows],
        )

    async def revision(
        self, *, user: User, trip_id: int, revision: int,
    ) -> TripTimelineRevisionResponse:
        await self.trips._require_trip_access(user=user, trip_id=trip_id)
        return self._full(await self._get(trip_id, revision))

    async def _get(self, trip_id: int, revision: int) -> TripTimelineRevision:
        row = (await self.session.execute(
            select(TripTimelineRevision).where(
                TripTimelineRevision.trip_id == trip_id,
                TripTimelineRevision.revision == revision,
            ),
        )).scalar_one_or_none()
        if row is None:
            raise LakbayAPIError(
                "That revision was not found.", code="trip_timeline_revision_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
            )
        return row

    async def _latest(self, trip_id: int) -> TripTimelineRevision | None:
        return (await self.session.execute(
            select(TripTimelineRevision)
            .where(TripTimelineRevision.trip_id == trip_id)
            .order_by(TripTimelineRevision.revision.desc()).limit(1),
        )).scalar_one_or_none()

    @staticmethod
    def _full(row: TripTimelineRevision) -> TripTimelineRevisionResponse:
        return TripTimelineRevisionResponse(
            revision=row.revision, created_at=row.created_at,
            created_by_user_id=row.created_by_user_id, changes=list(row.changes or []),
            state=PlanningState.model_validate(row.state),
            timeline=Timeline.model_validate(row.timeline),
        )

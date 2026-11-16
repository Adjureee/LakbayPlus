from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.features.commute.models import CommuteRoute, CommuteStep
from app.features.destinations.models import Destination


class CommuteRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def get_destination(self, destination_id: int) -> Destination | None:
        result = await self.session.execute(
            select(Destination).where(Destination.destination_id == destination_id)
        )
        return result.scalar_one_or_none()

    async def list_for_destination(
        self, destination_id: int, *, verified_only: bool,
    ) -> list[CommuteRoute]:
        statement = (
            select(CommuteRoute)
            .where(CommuteRoute.destination_id == destination_id)
            .order_by(CommuteRoute.commute_route_id)
        )
        if verified_only:
            statement = statement.where(
                CommuteRoute.is_verified.is_(True), CommuteRoute.is_active.is_(True),
            )
        result = await self.session.execute(statement)
        return list(result.scalars().all())

    async def get_route(self, commute_route_id: int) -> CommuteRoute | None:
        result = await self.session.execute(
            select(CommuteRoute).where(CommuteRoute.commute_route_id == commute_route_id)
        )
        return result.scalar_one_or_none()

    async def add_route(self, route: CommuteRoute) -> CommuteRoute:
        self.session.add(route)
        await self.session.flush()
        return route

    @staticmethod
    def build_steps(steps: list[dict]) -> list[CommuteStep]:
        return [CommuteStep(step_order=index, **step) for index, step in enumerate(steps, start=1)]

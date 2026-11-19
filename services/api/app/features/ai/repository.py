from sqlalchemy import or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.features.ai.models import AIGenerationRun
from app.features.destinations.catalog_selection import CatalogSelectionQueries
from app.features.destinations.models import Destination


class AIItineraryRepository(CatalogSelectionQueries):
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def list_active_destination_names(self) -> list[tuple[int, str]]:
        """(id, name) of every active destination, for recognizing a named place."""
        result = await self.session.execute(
            select(Destination.destination_id, Destination.name)
            .where(Destination.is_active.is_(True))
            .order_by(Destination.destination_id)
        )
        return [(row.destination_id, row.name) for row in result.all()]

    async def list_active_destination_ids_in_place(
        self, place: str, *, limit: int = 5,
    ) -> list[int]:
        """Ids of active destinations in a town or area, one per name.

        A place matches when its name, district or location contains the town.
        Names that start with the town come first. Catalog duplicates (the same
        name entered twice) are listed once.
        """
        term = f"%{place.strip()}%"
        result = await self.session.execute(
            select(Destination.destination_id, Destination.name)
            .where(
                Destination.is_active.is_(True),
                or_(
                    Destination.name.ilike(term),
                    Destination.district.ilike(term),
                    Destination.location.ilike(term),
                ),
            )
            .order_by(Destination.destination_id)
        )
        rows = result.all()
        wanted = place.strip().casefold()
        rows.sort(key=lambda row: (wanted not in row.name.casefold(), row.destination_id))
        seen: set[str] = set()
        ids: list[int] = []
        for row in rows:
            key = " ".join(row.name.split()).casefold()
            if key in seen:
                continue
            seen.add(key)
            ids.append(row.destination_id)
            if len(ids) >= limit:
                break
        return ids

    async def create_generation_run(
        self,
        *,
        user_id: int | None,
        request_purpose: str,
        model_role: str,
        model_id: str,
        prompt_version: str,
        input_summary: dict,
        fallback_used: bool = False,
    ) -> AIGenerationRun:
        run = AIGenerationRun(
            user_id=user_id,
            request_purpose=request_purpose,
            model_role=model_role,
            model_id=model_id,
            prompt_version=prompt_version,
            status="running",
            validation_status="pending",
            input_summary=input_summary,
            fallback_used=fallback_used,
        )
        self.session.add(run)
        await self.session.flush()

        return run

    async def update_generation_run(
        self,
        run: AIGenerationRun,
        *,
        status: str,
        validation_status: str,
        response_time_ms: int | None = None,
        prompt_tokens: int | None = None,
        completion_tokens: int | None = None,
        total_tokens: int | None = None,
        error_message: str | None = None,
        output_summary: dict | None = None,
    ) -> AIGenerationRun:
        run.status = status
        run.validation_status = validation_status
        run.response_time_ms = response_time_ms
        run.prompt_tokens = prompt_tokens
        run.completion_tokens = completion_tokens
        run.total_tokens = total_tokens
        run.error_message = error_message
        run.output_summary = output_summary
        await self.session.flush()

        return run

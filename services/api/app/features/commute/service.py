"""Commute directions: what travelers see, and what admins manage."""

from __future__ import annotations

from datetime import UTC, datetime
from time import perf_counter

from fastapi import status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.exceptions import LakbayAPIError
from app.features.ai.repository import AIItineraryRepository
from app.features.commute.draft import parse_commute_draft
from app.features.commute.models import CommuteRoute
from app.features.commute.repository import CommuteRepository
from app.features.commute.schemas import (
    CommuteDraftRequest,
    CommuteDraftResponse,
    CommuteOptionsResponse,
    CommuteRouteInput,
    CommuteRouteResponse,
)
from app.features.users.models import User
from app.integrations.groq.client import GroqClient
from app.integrations.groq.errors import GroqClientError, GroqRateLimitError
from app.integrations.groq.model_selector import select_fallback_models, select_primary_model
from app.integrations.groq.prompts import COMMUTE_DRAFT_PROMPT_VERSION, build_commute_draft_messages

COMMUTE_DRAFT_PURPOSE = "commute_draft"


def _response(route: CommuteRoute) -> CommuteRouteResponse:
    return CommuteRouteResponse.model_validate(route)


class CommuteService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.repo = CommuteRepository(session)

    async def _require_destination(self, destination_id: int):
        destination = await self.repo.get_destination(destination_id)
        if destination is None:
            raise LakbayAPIError(
                "Destination was not found.",
                code="destination_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
            )
        return destination

    async def _require_route(self, commute_route_id: int) -> CommuteRoute:
        route = await self.repo.get_route(commute_route_id)
        if route is None:
            raise LakbayAPIError(
                "Commute route was not found.",
                code="commute_route_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
            )
        return route

    # ---- travelers: only routes a person has verified -------------------------

    async def public_options(self, destination_id: int) -> CommuteOptionsResponse:
        destination = await self._require_destination(destination_id)
        if not destination.is_active:
            raise LakbayAPIError(
                "Destination was not found.",
                code="destination_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
            )
        routes = await self.repo.list_for_destination(destination_id, verified_only=True)
        return CommuteOptionsResponse(
            destination_id=destination_id, routes=[_response(r) for r in routes],
        )

    # ---- admins ---------------------------------------------------------------

    async def admin_options(self, destination_id: int) -> CommuteOptionsResponse:
        await self._require_destination(destination_id)
        routes = await self.repo.list_for_destination(destination_id, verified_only=False)
        return CommuteOptionsResponse(
            destination_id=destination_id, routes=[_response(r) for r in routes],
        )

    async def create(
        self, destination_id: int, data: CommuteRouteInput, admin: User,
    ) -> CommuteRouteResponse:
        await self._require_destination(destination_id)
        route = CommuteRoute(
            destination_id=destination_id,
            start_area=data.start_area,
            notes=data.notes,
            source_url=data.source_url,
            is_active=data.is_active,
        )
        route.steps = self.repo.build_steps([s.model_dump() for s in data.steps])
        self._apply_verification(route, data.is_verified, admin)
        await self.repo.add_route(route)
        await self.session.commit()
        await self.session.refresh(route)
        return _response(route)

    async def replace(
        self, commute_route_id: int, data: CommuteRouteInput, admin: User,
    ) -> CommuteRouteResponse:
        route = await self._require_route(commute_route_id)
        route.start_area = data.start_area
        route.notes = data.notes
        route.source_url = data.source_url
        route.is_active = data.is_active
        # Replace the steps as a whole, in the order given.
        route.steps.clear()
        await self.session.flush()
        route.steps.extend(self.repo.build_steps([s.model_dump() for s in data.steps]))
        self._apply_verification(route, data.is_verified, admin)
        await self.session.commit()
        await self.session.refresh(route)
        return _response(route)

    async def deactivate(self, commute_route_id: int) -> CommuteRouteResponse:
        route = await self._require_route(commute_route_id)
        route.is_active = False
        await self.session.commit()
        await self.session.refresh(route)
        return _response(route)

    @staticmethod
    def _apply_verification(route: CommuteRoute, wanted: bool, admin: User) -> None:
        """Record who verified a route and when; unverifying clears both."""
        if wanted and not route.is_verified:
            route.is_verified = True
            route.verified_at = datetime.now(UTC)
            route.verified_by_user_id = admin.user_id
        elif not wanted:
            route.is_verified = False
            route.verified_at = None
            route.verified_by_user_id = None

    # ---- AI draft (admin only, never saved, never verified) ----------------------

    async def draft(
        self,
        destination_id: int,
        data: CommuteDraftRequest,
        admin: User,
        groq_client: GroqClient,
    ) -> CommuteDraftResponse:
        # Imported here: the AI module is large and imports many features.
        from app.features.ai.service import _reserve_user_ai_call

        destination = await self._require_destination(destination_id)
        notes = (data.notes or destination.how_to_get_there or "").strip()
        if not notes:
            raise LakbayAPIError(
                "This place has no how-to-get-there notes to draft from. Add notes first.",
                code="commute_draft_no_notes",
                status_code=status.HTTP_400_BAD_REQUEST,
            )
        settings = get_settings()
        primary = select_primary_model(settings=settings, model_role="default")
        if primary is None:
            raise LakbayAPIError(
                "A Groq model is not configured.",
                code="ai_model_not_configured",
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            )
        selections = [primary, *select_fallback_models(settings=settings, primary_model_id=primary.model_id)]
        messages = build_commute_draft_messages(
            name=destination.name, district=destination.district, notes=notes,
        )
        ai = AIItineraryRepository(self.session)

        last_error: str | None = None
        for selection in selections:
            _reserve_user_ai_call(
                admin.user_id, settings, count_daily=not selection.fallback_used,
            )
            run = await ai.create_generation_run(
                user_id=admin.user_id,
                request_purpose=COMMUTE_DRAFT_PURPOSE,
                model_role=selection.model_role,
                model_id=selection.model_id,
                prompt_version=COMMUTE_DRAFT_PROMPT_VERSION,
                input_summary={"destination_id": destination_id, "notes_length": len(notes)},
                fallback_used=selection.fallback_used,
            )
            await self.session.commit()
            started = perf_counter()
            try:
                completion = await groq_client.create_chat_completion(
                    model=selection.model_id,
                    messages=messages,
                    response_format={"type": "json_object"},
                    provider=selection.provider,
                    temperature=0.1,
                )
            except GroqClientError as exc:
                await ai.update_generation_run(
                    run, status="failed", validation_status="not_run",
                    response_time_ms=int((perf_counter() - started) * 1000),
                    error_message=exc.message,
                )
                await self.session.commit()
                last_error = exc.message
                if isinstance(exc, GroqRateLimitError):
                    continue
                continue

            parsed = parse_commute_draft(completion.content)
            await ai.update_generation_run(
                run,
                status="succeeded" if parsed is not None else "failed",
                validation_status="valid" if parsed is not None else "invalid",
                response_time_ms=int((perf_counter() - started) * 1000),
                prompt_tokens=completion.prompt_tokens,
                completion_tokens=completion.completion_tokens,
                total_tokens=completion.total_tokens,
                error_message=None if parsed is not None else "Draft was not valid JSON.",
            )
            await self.session.commit()
            if parsed is None:
                last_error = "The AI answer could not be read."
                continue
            routes, unclear = parsed
            return CommuteDraftResponse(
                destination_id=destination_id,
                source_text=notes,
                routes=routes,
                unclear=unclear,
                model_id=selection.model_id,
            )

        raise LakbayAPIError(
            last_error or "The AI could not draft commute steps.",
            code="commute_draft_failed",
            status_code=status.HTTP_502_BAD_GATEWAY,
        )

import json
import logging
import re
from decimal import Decimal
from time import perf_counter

from fastapi import status
from pydantic import ValidationError
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings, get_settings
from app.core.exceptions import LakbayAPIError
from app.core.provider_usage import ProviderLimiter
from app.features.accommodations.models import Accommodation
from app.features.ai.models import AIGenerationRun
from app.features.ai.destination_resolver import (
    _distinctive,
    _tokens,
    match_destinations,
    pick_single_destination,
)
from app.features.ai.geo_context import selected_geo_inputs
from app.features.ai.repository import AIItineraryRepository
from app.features.ai.rag import VectorRAGRetriever
from app.features.ai.schemas import (
    AIChatRequest,
    AIChatResponse,
    AIPlaceQuery,
    AIPlanningChatOutput,
    AIPlanningChatResult,
    AIPlanningStateUpdates,
    AIItineraryGenerateRequest,
    AIItineraryGenerateResponse,
    AIModelRunResult,
    AITripDraftRequest,
    AITripDraftResponse,
)
from app.features.ai.validators import (
    AIItineraryCatalog,
    AIOutputInvalidJsonError,
    AIOutputValidationError,
    parse_and_validate_itinerary_output,
)
from app.features.destinations.catalog_selection import (
    require_all_accommodations,
    require_all_destinations,
    require_all_transportations,
    require_rates_belong_to_destinations,
)
from app.features.destinations.service import DestinationService
from app.features.destinations.models import Destination
from app.features.destinations.region import (
    canonical_province_name,
    nearest_provinces,
    province_for_destination,
    region_status,
)
from app.features.ai.conversation_stage import compute_stage
from app.features.planning.schemas import PlanningOrigin, PlanningPreviewRequest, PlanningPreviewResponse, PlanningState
from app.features.planning.service import PlanningService
from app.features.recommendations.limits import MAX_SUGGESTIONS
from app.features.recommendations.schemas import (
    PlanningRecommendationItem,
    TopPlacesRequest,
)
from app.features.recommendations.service import (
    RecommendationService,
    planning_recommendation_from_top_place,
)
from app.features.routes.schemas import RouteCoordinate
from app.features.routes.service import RouteService
from app.features.transportations.models import Transportation
from app.features.users.models import User
from app.integrations.groq.client import GroqClient
from app.integrations.groq.errors import GroqClientError, GroqRateLimitError
from app.integrations.groq.itinerary_schema import ITINERARY_RESPONSE_FORMAT
from app.integrations.groq.model_selector import (
    ModelSelection,
    select_comparison_models,
    select_fallback_models,
    select_primary_model,
)
from app.integrations.groq.prompts import (
    CHAT_PROMPT_VERSION,
    ONBOARDING_CHAT_PROMPT_VERSION,
    PLANNING_PROMPT_VERSION,
    PROMPT_VERSION,
    build_chat_messages,
    build_geo_analytics_context,
    build_itinerary_messages,
    build_json_retry_nudge_messages,
    build_trip_draft_messages,
    TRIP_DRAFT_PROMPT_VERSION,
)

REQUEST_PURPOSE = "itinerary_generation"
GUEST_ITINERARY_REQUEST_PURPOSE = "guest_itinerary_generation"
CHAT_REQUEST_PURPOSE = "travel_chat"
GUEST_CHAT_REQUEST_PURPOSE = "guest_travel_chat"
TRIP_DRAFT_REQUEST_PURPOSE = "trip_draft"
GUEST_TRIP_DRAFT_REQUEST_PURPOSE = "guest_trip_draft"
# Destination names sent to ground a draft; enough for variety, few tokens.
TRIP_DRAFT_CATALOG_LIMIT = 80
_ai_user_limiter = ProviderLimiter()
_timing_log = logging.getLogger("app.ai.timing")


def _log_timing(stage: str, started_at: float, **extra: object) -> None:
    """Log how long a stage of an AI request took; never logs user content."""
    details = " ".join(f"{key}={value}" for key, value in extra.items())
    _timing_log.info(
        "ai_timing stage=%s ms=%d %s", stage, _elapsed_ms(started_at), details
    )


def _reserve_user_ai_call(
    user_id: int,
    settings: Settings,
    *,
    count_daily: bool = True,
) -> None:
    _ai_user_limiter.reserve(
        f"groq:user:{user_id}",
        limit=settings.groq_user_requests_per_minute,
        code="ai_user_rate_limit_exceeded",
        message="Too many AI requests. Please try again shortly.",
    )
    # Fallback attempts for the same request must not use up the daily allowance.
    if count_daily:
        _ai_user_limiter.reserve(
            f"groq:user:{user_id}:day",
            limit=settings.groq_user_requests_per_day,
            window_seconds=86400,
            code="ai_user_daily_limit_exceeded",
            message="You have reached today's AI limit. Please try again tomorrow.",
        )


def _reserve_guest_ai_call(
    guest_key: str,
    settings: Settings,
    *,
    count_daily: bool = True,
) -> None:
    _ai_user_limiter.reserve(
        f"groq:guest:{guest_key}",
        limit=settings.guest_ai_requests_per_minute,
        code="ai_guest_rate_limit_exceeded",
        message="Too many AI requests. Please try again shortly.",
    )
    if count_daily:
        _ai_user_limiter.reserve(
            f"groq:guest:{guest_key}:day",
            limit=settings.guest_ai_requests_per_day,
            window_seconds=86400,
            code="ai_guest_daily_limit_exceeded",
            message=(
                "You have reached today's guest AI limit. Sign in to keep chatting."
            ),
        )
        _ai_user_limiter.reserve(
            "groq:guest:all:day",
            limit=settings.guest_ai_global_requests_per_day,
            window_seconds=86400,
            code="ai_guest_capacity_reached",
            message="Guest chat is busy today. Sign in to keep chatting.",
        )


def _groq_rate_limit_response(exc: GroqRateLimitError) -> LakbayAPIError:
    return LakbayAPIError(
        exc.message,
        code="groq_rate_limit_exceeded",
        status_code=429,
        details={"retry_after_seconds": exc.retry_after_seconds},
        headers={"Retry-After": str(exc.retry_after_seconds)},
    )


class AIItineraryService:
    def __init__(
        self,
        session: AsyncSession,
        groq_client: GroqClient,
        route_service: RouteService | None = None,
    ) -> None:
        self.session = session
        self.ai = AIItineraryRepository(session)
        self.groq_client = groq_client
        self.route_service = route_service

    async def generate_itinerary(
        self,
        *,
        user: User | None,
        data: AIItineraryGenerateRequest,
        guest_key: str | None = None,
    ) -> AIItineraryGenerateResponse:
        if user is None and not guest_key:
            raise ValueError("Guest itinerary generation needs a guest_key.")
        settings = get_settings()
        planning_preview: PlanningPreviewResponse | None = None
        if data.planning_state is not None:
            planning_preview = await PlanningService(self.session, self.route_service).preview(
                PlanningPreviewRequest(input_revision=data.input_revision, state=data.planning_state)
            )
            _validate_generation_planning_state(data, planning_preview)
        destinations = await self.ai.list_active_destinations_by_ids(
            list(data.destination_ids),
        )
        require_all_destinations(data.destination_ids, destinations)

        accommodations = await self.ai.list_available_accommodations_by_ids(
            list(data.accommodation_ids),
        )
        require_all_accommodations(data.accommodation_ids, accommodations)

        transportations = await self.ai.list_available_transportations_by_ids(
            list(data.transportation_ids),
        )
        require_all_transportations(data.transportation_ids, transportations)
        require_rates_belong_to_destinations(
            accommodations=accommodations,
            transportations=transportations,
            destination_ids=set(data.destination_ids),
        )

        geo_analytics_context = None
        route_destination_order = None
        if planning_preview is not None:
            route = planning_preview.route
            if route.status == "calculated" and route.summary is not None:
                route_destination_order = tuple(
                    stop.destination_id
                    for stop in route.summary.stops
                    if not stop.is_origin and stop.destination_id is not None
                )
            recommendations, scored_groups = await selected_geo_inputs(
                session=self.session,
                user=user,
                preview=planning_preview,
                destinations=destinations,
                routes=self.route_service if user is not None else None,
                interests=data.interests,
            )
            geo_analytics_context = build_geo_analytics_context(
                planning_preview,
                recommendations=recommendations,
                scored_groups=scored_groups,
            )

        selections = self._select_models(settings=settings, data=data)
        catalog_payload = _build_catalog_payload(
            destinations=destinations,
            accommodations=accommodations,
            transportations=transportations,
        )
        validator_catalog = AIItineraryCatalog(
            destination_ids={destination.destination_id for destination in destinations},
            accommodation_ids={
                accommodation.accommodation_id for accommodation in accommodations
            },
            transportation_ids={
                transportation.transportation_id for transportation in transportations
            },
            total_budget=Decimal(data.total_budget),
            day_count=data.day_count,
            minimum_option_count=settings.ai_itinerary_option_count,
            required_destination_ids=set(data.destination_ids),
            route_destination_order=route_destination_order,
            required_accommodation_ids=set(data.accommodation_ids) if planning_preview else None,
            required_transportation_ids=set(data.transportation_ids) if planning_preview else None,
            accommodation_destination_ids={
                item.accommodation_id: item.destination_id for item in accommodations
            } if planning_preview else None,
            transportation_destination_ids={
                item.transportation_id: item.destination_id for item in transportations
            } if planning_preview else None,
        )
        messages = build_itinerary_messages(
            request=data,
            catalog=catalog_payload,
            option_count=settings.ai_itinerary_option_count,
            planning_preview=planning_preview,
            geo_analytics_context=geo_analytics_context,
            route_destination_order=route_destination_order,
        )
        quality_warnings = _itinerary_quality_warnings(
            destinations=destinations,
            transportations=transportations,
            traveler_count=data.traveler_count,
            planning_preview=planning_preview,
        )

        model_runs: list[AIModelRunResult] = []
        primary_options = []

        rate_limit_error: LakbayAPIError | None = None

        for selection in selections:
            try:
                run_result = await self._run_model_generation(
                    user=user,
                    guest_key=guest_key,
                    data=data,
                    selection=selection,
                    messages=messages,
                    catalog=validator_catalog,
                    option_count=settings.ai_itinerary_option_count,
                    planning_preview=planning_preview,
                    geo_analytics_context=geo_analytics_context,
                    quality_warnings=quality_warnings,
                )
            except LakbayAPIError as exc:
                # On a rate limit, try the next (fallback) selection if there is one.
                if (
                    exc.code != "groq_rate_limit_exceeded"
                    or data.compare_models
                    or selection is selections[-1]
                ):
                    raise
                rate_limit_error = exc
                continue
            model_runs.append(run_result)

            if run_result.status == "succeeded" and not primary_options:
                primary_options = run_result.options

            if run_result.status == "succeeded" and not data.compare_models:
                break

        if not primary_options and rate_limit_error is not None and not model_runs:
            raise rate_limit_error

        if not primary_options:
            raise LakbayAPIError(
                "AI itinerary generation failed.",
                code="ai_generation_failed",
                status_code=status.HTTP_502_BAD_GATEWAY,
                details={
                    "model_runs": [
                        run.model_dump(exclude={"options"}) for run in model_runs
                    ],
                },
            )

        return AIItineraryGenerateResponse(
            options=primary_options,
            model_runs=model_runs,
            selected_generation_run_id=next(
                run.ai_generation_run_id for run in model_runs if run.status == "succeeded"
            ) if planning_preview else None,
            planning_preview=planning_preview,
            geo_analytics_context=geo_analytics_context,
        )

    async def chat(
        self,
        *,
        user: User | None,
        data: AIChatRequest,
        guest_key: str | None = None,
    ) -> AIChatResponse:
        """Chat for a signed-in user, or a guest identified by ``guest_key``."""
        if user is None and not guest_key:
            raise ValueError("Guest chat needs a guest_key.")
        chat_started = perf_counter()
        settings = get_settings()
        selections = self._select_chat_models(
            settings=settings,
            model_role=data.model_role,
            allow_fallback=data.allow_fallback,
        )
        rag_matches = []
        retrieval_coverage = {"status": "disabled", "destinations": [], "truncated": False}
        if data.use_rag and data.rag_limit > 0:
            retriever = VectorRAGRetriever(self.session)
            rag_matches = await retriever.retrieve(
                data.message,
                limit=data.rag_limit,
                history=[item.content for item in data.history if item.role == "user"],
                context=data.context,
            )
            retrieval_coverage = retriever.coverage
            _log_timing("retrieval", chat_started, matches=len(rag_matches))

        retrieved_context = [match.to_prompt_dict() for match in rag_matches]
        picked_places: list[dict] = []
        if data.planning_state is not None and data.planning_state.destination_ids:
            picked = await self.ai.list_active_destinations_by_ids(
                list(data.planning_state.destination_ids),
            )
            by_id = {item.destination_id: item for item in picked}
            picked_places = [
                {
                    "destination_id": destination_id,
                    "name": by_id[destination_id].name,
                    "district": by_id[destination_id].district,
                    "category": by_id[destination_id].category,
                }
                for destination_id in data.planning_state.destination_ids
                if destination_id in by_id
            ]
        available_categories = (
            [
                item.model_dump(include={"key", "label", "count", "examples"})
                for item in (await DestinationService(self.session).facets()).categories
            ]
            if data.planning_state is not None
            else None
        )
        messages = build_chat_messages(
            request=data,
            retrieved_context=retrieved_context,
            retrieval_coverage=retrieval_coverage,
            picked_places=picked_places,
            available_categories=available_categories,
        )
        failed_runs: list[dict] = []
        rate_limit_error: GroqRateLimitError | None = None

        for selection in selections:
            if user is not None:
                _reserve_user_ai_call(
                    user.user_id, settings, count_daily=not selection.fallback_used
                )
            else:
                _reserve_guest_ai_call(
                    guest_key, settings, count_daily=not selection.fallback_used
                )
            run = await self.ai.create_generation_run(
                user_id=user.user_id if user is not None else None,
                request_purpose=(
                    CHAT_REQUEST_PURPOSE if user is not None else GUEST_CHAT_REQUEST_PURPOSE
                ),
                model_role=selection.model_role,
                model_id=selection.model_id,
                prompt_version=(
                    ONBOARDING_CHAT_PROMPT_VERSION
                    if data.is_onboarding
                    else CHAT_PROMPT_VERSION
                ),
                input_summary=_build_chat_input_summary(data),
                fallback_used=selection.fallback_used,
            )
            await self.session.commit()
            await self.session.refresh(run)

            started_at = perf_counter()

            try:
                completion = await self.groq_client.create_chat_completion(
                    model=selection.model_id,
                    messages=messages,
                    provider=selection.provider,
                    temperature=settings.groq_chat_temperature,
                )
                response_time_ms = _elapsed_ms(started_at)
                _log_timing(
                    "model", started_at,
                    model=selection.model_id, provider=selection.provider,
                    prompt_tokens=completion.prompt_tokens,
                    completion_tokens=completion.completion_tokens,
                )
                planning_result = None
                validation_status = "not_run"
                if data.planning_state is None:
                    chat_response = _restore_line_breaks(completion.content.strip()) or (
                        "I could not generate a helpful answer just now. "
                        "Please try asking in another way."
                    )
                else:
                    planning_started = perf_counter()
                    # Recognize a place the traveler named even if the model does not.
                    # Also needed after stops are picked, so a place the traveler names
                    # later can still be recognized by name.
                    catalog = await self.ai.list_active_destination_names()
                    (
                        chat_response,
                        planning_result,
                        validation_status,
                    ) = await _build_planning_chat_result(
                        content=completion.content,
                        data=data,
                        session=self.session,
                        route_service=self.route_service,
                        retrieved_destination_ids={
                            match.source_id
                            for match in rag_matches
                            if match.source == "destination"
                        },
                        # Ordered by relevance, for suggestion cards when the traveler
                        # names a place but no destination is selected yet.
                        named_destination_ids=[
                            match.source_id
                            for match in rag_matches
                            if match.source == "destination"
                        ],
                        requested_locations=list(
                            retrieval_coverage.get("requested_locations") or []
                        ),
                        retrieval_interest=retrieval_coverage.get("interest"),
                        catalog=catalog,
                    )
                    _log_timing("planning_total", planning_started)
                updated_run = await self.ai.update_generation_run(
                    run,
                    status="succeeded",
                    validation_status=validation_status,
                    response_time_ms=response_time_ms,
                    prompt_tokens=completion.prompt_tokens,
                    completion_tokens=completion.completion_tokens,
                    total_tokens=completion.total_tokens,
                    output_summary={
                        "response_length": len(chat_response),
                        "retrieved_context_count": len(retrieved_context),
                        "planning_update_status": (
                            planning_result.update_status if planning_result else None
                        ),
                        "planning_input_revision": (
                            planning_result.input_revision if planning_result else None
                        ),
                    },
                )
                await self.session.commit()
                await self.session.refresh(updated_run)

                _log_timing("chat_total", chat_started)
                return AIChatResponse(
                    chat_response=chat_response,
                    mode="rag_chat" if retrieved_context else "chat",
                    model_role=updated_run.model_role,
                    model_id=updated_run.model_id,
                    ai_generation_run_id=updated_run.ai_generation_run_id,
                    retrieved_context=[
                        match.to_response_dict() for match in rag_matches
                    ],
                    planning=planning_result,
                    response_time_ms=updated_run.response_time_ms,
                    prompt_tokens=updated_run.prompt_tokens,
                    completion_tokens=updated_run.completion_tokens,
                    total_tokens=updated_run.total_tokens,
                )
            except GroqClientError as exc:
                updated_run = await self.ai.update_generation_run(
                    run,
                    status="failed",
                    validation_status="not_run",
                    response_time_ms=_elapsed_ms(started_at),
                    error_message=exc.message,
                )
                await self.session.commit()
                await self.session.refresh(updated_run)
                if isinstance(exc, GroqRateLimitError):
                    # Try the fallback provider/model before giving up.
                    rate_limit_error = exc
                failed_runs.append(
                    {
                        "ai_generation_run_id": updated_run.ai_generation_run_id,
                        "model_role": updated_run.model_role,
                        "model_id": updated_run.model_id,
                        "error_message": updated_run.error_message,
                    }
                )

        if rate_limit_error is not None:
            raise _groq_rate_limit_response(rate_limit_error) from rate_limit_error

        raise LakbayAPIError(
            "AI chat failed.",
            code="ai_chat_failed",
            status_code=status.HTTP_502_BAD_GATEWAY,
            details={"model_runs": failed_runs},
        )

    def _select_models(
        self,
        *,
        settings: Settings,
        data: AIItineraryGenerateRequest,
    ) -> list[ModelSelection]:
        if data.compare_models:
            if not settings.ai_model_comparison_enabled:
                raise LakbayAPIError(
                    "AI model comparison is disabled.",
                    code="ai_model_comparison_disabled",
                    status_code=status.HTTP_400_BAD_REQUEST,
                )

            comparison_models = select_comparison_models(settings=settings)

            if len(comparison_models) < 2:
                raise LakbayAPIError(
                    "At least two comparison models must be configured.",
                    code="ai_comparison_models_not_configured",
                    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                )

            return comparison_models

        primary = select_primary_model(settings=settings, model_role=data.model_role)

        if primary is None:
            raise LakbayAPIError(
                "A Groq model is not configured for itinerary generation.",
                code="ai_model_not_configured",
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            )

        selections = [primary]

        if data.allow_fallback:
            selections.extend(
                select_fallback_models(
                    settings=settings,
                    primary_model_id=primary.model_id,
                    for_itinerary=True,
                )
            )

        return selections

    async def trip_draft(
        self,
        *,
        user: User | None,
        data: AITripDraftRequest,
        guest_key: str | None = None,
    ) -> AITripDraftResponse:
        """Quick structured trip draft for onboarding and prompt-to-trip flows."""
        if user is None and not guest_key:
            raise ValueError("A guest trip draft needs a guest_key.")
        settings = get_settings()
        selections = self._select_chat_models(
            settings=settings, model_role="default", allow_fallback=True,
        )
        names = [name for _, name in await self.ai.list_active_destination_names()]
        messages = build_trip_draft_messages(
            request=data, catalog_names=names[:TRIP_DRAFT_CATALOG_LIMIT],
        )
        rate_limit_error: GroqRateLimitError | None = None
        for selection in selections:
            if user is not None:
                _reserve_user_ai_call(
                    user.user_id, settings, count_daily=not selection.fallback_used,
                )
            else:
                _reserve_guest_ai_call(
                    guest_key, settings, count_daily=not selection.fallback_used,
                )
            run = await self.ai.create_generation_run(
                user_id=user.user_id if user is not None else None,
                request_purpose=(
                    TRIP_DRAFT_REQUEST_PURPOSE if user is not None
                    else GUEST_TRIP_DRAFT_REQUEST_PURPOSE
                ),
                model_role=selection.model_role,
                model_id=selection.model_id,
                prompt_version=TRIP_DRAFT_PROMPT_VERSION,
                input_summary={
                    "message_length": len(data.message),
                    "history_count": len(data.history),
                    "has_coordinates": data.user_lat is not None,
                    "language": data.language,
                },
                fallback_used=selection.fallback_used,
            )
            await self.session.commit()
            started_at = perf_counter()
            try:
                completion = await self.groq_client.create_chat_completion(
                    model=selection.model_id,
                    messages=messages,
                    response_format={"type": "json_object"},
                    provider=selection.provider,
                    temperature=settings.groq_chat_temperature,
                )
            except GroqClientError as exc:
                await self.ai.update_generation_run(
                    run, status="failed", validation_status="not_run",
                    response_time_ms=_elapsed_ms(started_at), error_message=exc.message,
                )
                await self.session.commit()
                if isinstance(exc, GroqRateLimitError):
                    rate_limit_error = exc
                continue

            draft = _parse_trip_draft(completion.content)
            await self.ai.update_generation_run(
                run,
                status="succeeded" if draft is not None else "failed",
                validation_status="valid" if draft is not None else "invalid",
                response_time_ms=_elapsed_ms(started_at),
                prompt_tokens=completion.prompt_tokens,
                completion_tokens=completion.completion_tokens,
                total_tokens=completion.total_tokens,
                error_message=None if draft is not None else "Draft was not valid JSON.",
            )
            await self.session.commit()
            if draft is not None:
                return AITripDraftResponse(
                    draft=draft, model_id=selection.model_id, provider=selection.provider,
                )

        if rate_limit_error is not None:
            raise _groq_rate_limit_response(rate_limit_error) from rate_limit_error
        raise LakbayAPIError(
            "AI trip draft failed.",
            code="ai_trip_draft_failed",
            status_code=status.HTTP_502_BAD_GATEWAY,
        )

    def _select_chat_models(
        self,
        *,
        settings: Settings,
        model_role: str,
        allow_fallback: bool,
    ) -> list[ModelSelection]:
        primary = select_primary_model(settings=settings, model_role=model_role)

        if primary is None:
            raise LakbayAPIError(
                "A Groq model is not configured for AI chat.",
                code="ai_model_not_configured",
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            )

        selections = [primary]

        if allow_fallback:
            selections.extend(
                select_fallback_models(
                    settings=settings,
                    primary_model_id=primary.model_id,
                )
            )

        return selections

    async def _run_model_generation(
        self,
        *,
        user: User | None,
        guest_key: str | None = None,
        data: AIItineraryGenerateRequest,
        selection: ModelSelection,
        messages: list[dict[str, str]],
        catalog: AIItineraryCatalog,
        option_count: int,
        planning_preview: PlanningPreviewResponse | None = None,
        geo_analytics_context: dict | None = None,
        quality_warnings: list[str] | None = None,
    ) -> AIModelRunResult:
        settings = get_settings()
        if user is not None:
            _reserve_user_ai_call(
                user.user_id, settings, count_daily=not selection.fallback_used
            )
        else:
            assert guest_key is not None
            _reserve_guest_ai_call(
                guest_key, settings, count_daily=not selection.fallback_used
            )
        run = await self.ai.create_generation_run(
            user_id=user.user_id if user is not None else None,
            request_purpose=(
                REQUEST_PURPOSE
                if user is not None
                else GUEST_ITINERARY_REQUEST_PURPOSE
            ),
            model_role=selection.model_role,
            model_id=selection.model_id,
            prompt_version=(
                PLANNING_PROMPT_VERSION if planning_preview is not None else PROMPT_VERSION
            ),
            input_summary=_build_input_summary(data),
            fallback_used=selection.fallback_used,
        )
        await self.session.commit()
        await self.session.refresh(run)

        started_at = perf_counter()
        json_retry_used = False

        try:
            completion = await self.groq_client.create_chat_completion(
                model=selection.model_id,
                messages=messages,
                response_format=ITINERARY_RESPONSE_FORMAT,
                provider=selection.provider,
                max_tokens=settings.groq_itinerary_max_tokens,
                max_rate_limit_wait_seconds=settings.groq_itinerary_rate_limit_max_wait_seconds,
            )
            prompt_tokens = completion.prompt_tokens
            completion_tokens = completion.completion_tokens
            total_tokens = completion.total_tokens
            try:
                options = parse_and_validate_itinerary_output(
                    content=completion.content,
                    catalog=catalog,
                )
            except AIOutputInvalidJsonError:
                json_retry_used = True
                nudge_messages = build_json_retry_nudge_messages(messages)
                completion = await self.groq_client.create_chat_completion(
                    model=selection.model_id,
                    messages=nudge_messages,
                    response_format=ITINERARY_RESPONSE_FORMAT,
                    provider=selection.provider,
                    max_tokens=settings.groq_itinerary_max_tokens,
                    max_rate_limit_wait_seconds=settings.groq_itinerary_rate_limit_max_wait_seconds,
                )
                prompt_tokens = _sum_tokens(prompt_tokens, completion.prompt_tokens)
                completion_tokens = _sum_tokens(completion_tokens, completion.completion_tokens)
                total_tokens = _sum_tokens(total_tokens, completion.total_tokens)
                options = parse_and_validate_itinerary_output(
                    content=completion.content,
                    catalog=catalog,
                )
            response_time_ms = _elapsed_ms(started_at)
            options = [
                option.model_copy(update={"quality_warnings": list(quality_warnings or [])})
                for option in options
            ]
            if data.strict_budget_filter:
                options = _apply_strict_budget_filter(
                    options=options,
                    total_budget=Decimal(data.total_budget),
                )
            updated_run = await self.ai.update_generation_run(
                run,
                status="succeeded",
                validation_status="valid",
                response_time_ms=response_time_ms,
                prompt_tokens=prompt_tokens,
                completion_tokens=completion_tokens,
                total_tokens=total_tokens,
                output_summary={
                    "option_count": len(options),
                    "minimum_option_count": option_count,
                    **({"json_retry_used": True} if json_retry_used else {}),
                    **({
                        "options": [option.model_dump(mode="json") for option in options],
                        "planning_preview": planning_preview.model_dump(mode="json"),
                        "geo_analytics_context": geo_analytics_context,
                    } if planning_preview is not None else {}),
                },
            )
            await self.session.commit()
            await self.session.refresh(updated_run)

            return _build_run_result(run=updated_run, options=options)
        except AIOutputValidationError as exc:
            failure_cause = (
                "invalid_json"
                if isinstance(exc, AIOutputInvalidJsonError)
                else "validation_failed"
            )
            updated_run = await self.ai.update_generation_run(
                run,
                status="failed",
                validation_status="invalid",
                response_time_ms=_elapsed_ms(started_at),
                error_message=exc.message,
                output_summary={
                    "validation_errors": exc.details,
                    "failure_cause": failure_cause,
                    **({"json_retry_used": True} if json_retry_used else {}),
                },
            )
            await self.session.commit()
            await self.session.refresh(updated_run)

            return _build_run_result(run=updated_run, options=[])
        except GroqClientError as exc:
            updated_run = await self.ai.update_generation_run(
                run,
                status="failed",
                validation_status="not_run",
                response_time_ms=_elapsed_ms(started_at),
                error_message=exc.message,
                output_summary={"failure_cause": _classify_groq_error(exc)},
            )
            await self.session.commit()
            await self.session.refresh(updated_run)

            if isinstance(exc, GroqRateLimitError):
                raise _groq_rate_limit_response(exc) from exc

            return _build_run_result(run=updated_run, options=[])


def _itinerary_quality_warnings(
    *,
    destinations: list[Destination],
    transportations: list[Transportation],
    traveler_count: int,
    planning_preview: PlanningPreviewResponse | None,
) -> list[str]:
    warnings: list[str] = []
    for destination in destinations:
        warnings.append(
            f"Current opening hours for {destination.name} are not verified by Lakbay; "
            "confirm before traveling."
        )
        access_text = " ".join(
            part for part in (destination.description, destination.how_to_get_there) if part
        )
        if re.search(r"\b(ferry|boat)\b", access_text, flags=re.IGNORECASE):
            has_priced_ferry = any(
                transportation.destination_id == destination.destination_id
                and transportation.charging_unit is not None
                and re.search(
                    r"\b(ferry|boat)\b",
                    " ".join((transportation.vehicle_type, transportation.transport_mode)),
                    flags=re.IGNORECASE,
                )
                for transportation in transportations
            )
            if not has_priced_ferry:
                warnings.append(
                    f"The ferry or boat fare for {destination.name} has no selected "
                    "catalog rate with a known charging unit; confirm and add this cost."
                )

    if traveler_count > 1:
        warnings.append(
            f"AI costs are draft estimates; confirm the full cost for {traveler_count} travelers."
        )
    if planning_preview is None:
        warnings.append(
            "Travel times and visitor arrival access have not been checked against a route."
        )
    return warnings


def _build_catalog_payload(
    *,
    destinations: list[Destination],
    accommodations: list[Accommodation],
    transportations: list[Transportation],
) -> dict:
    return {
        "destinations": [
            {
                "destination_id": destination.destination_id,
                "name": destination.name,
                "description": destination.description,
                "district": destination.district,
                "location": destination.location,
                "category": destination.category,
                "vibes": destination.vibes,
                "activities": destination.activities,
                "lat": destination.lat,
                "lng": destination.lng,
                "arrival_lat": destination.arrival_lat,
                "arrival_lng": destination.arrival_lng,
                "route_ready": destination.route_ready,
                "estimated_cost": (
                    str(destination.estimated_cost)
                    if destination.estimated_cost is not None else None
                ),
                "entrance_fee": destination.entrance_fee,
                "overnight_fee": destination.overnight_fee,
                "operating_hours": destination.operating_hours,
                "best_time_to_visit": destination.best_time_to_visit,
                "how_to_get_there": destination.how_to_get_there,
                "estimated_travel_time": destination.estimated_travel_time,
                "travel_notes": destination.travel_notes,
                "what_to_bring": destination.what_to_bring,
                "difficulty_level": destination.difficulty_level,
                "stay_duration_type": destination.stay_duration_type,
            }
            for destination in destinations
        ],
        "accommodations": [
            {
                "accommodation_id": accommodation.accommodation_id,
                "destination_id": accommodation.destination_id,
                "name": accommodation.name,
                "room_type": accommodation.room_type,
                "price": str(accommodation.price),
                "currency": accommodation.currency,
                "charging_unit": accommodation.charging_unit,
                "capacity": accommodation.capacity,
                "description": accommodation.description,
            }
            for accommodation in accommodations
        ],
        "transportations": [
            {
                "transportation_id": transportation.transportation_id,
                "destination_id": transportation.destination_id,
                "vehicle_type": transportation.vehicle_type,
                "transport_mode": transportation.transport_mode,
                "route_from": transportation.route_from,
                "route_to": transportation.route_to,
                "price": str(transportation.price),
                "currency": transportation.currency,
                "charging_unit": transportation.charging_unit,
                "duration_minutes": transportation.duration_minutes,
                "duration_text": transportation.duration_text,
                "notes": transportation.notes,
            }
            for transportation in transportations
        ],
    }


def _build_input_summary(data: AIItineraryGenerateRequest) -> dict:
    return {
        "total_budget": str(data.total_budget),
        "traveler_count": data.traveler_count,
        "day_count": data.day_count,
        "destination_ids": list(data.destination_ids),
        "accommodation_ids": list(data.accommodation_ids),
        "transportation_ids": list(data.transportation_ids),
        "interests": list(data.interests),
        "travel_style": data.travel_style,
        "language": data.language,
        "compare_models": data.compare_models,
        "planning_enabled": data.planning_state is not None,
        "input_revision": data.input_revision if data.planning_state is not None else None,
    }


def _validate_generation_planning_state(
    data: AIItineraryGenerateRequest,
    preview: PlanningPreviewResponse,
) -> None:
    state = preview.state
    selected_transport_ids = {
        option.transportation_id for option in preview.transport_options
        if option.selected and option.transportation_id is not None
    }
    if preview.selection_problems:
        raise LakbayAPIError(
            "Review planning selections before generating an itinerary.",
            code="planning_selection_invalid",
            status_code=status.HTTP_400_BAD_REQUEST,
            details={"selection_problems": [item.model_dump() for item in preview.selection_problems]},
        )
    if preview.budget.minimum_over_budget_amount > 0:
        raise LakbayAPIError(
            "The selected plan already exceeds the budget estimate.",
            code="planning_over_budget",
            status_code=status.HTTP_409_CONFLICT,
        )
    if (
        data.destination_ids != state.destination_ids
        or set(data.accommodation_ids) != set(state.selected_accommodation_ids)
        or set(data.transportation_ids) != selected_transport_ids
        or data.traveler_count != state.traveler_count
        or data.day_count != state.day_count
        or data.total_budget != preview.whole_trip_budget
    ):
        raise LakbayAPIError(
            "AI generation inputs must match the selected planning preview.",
            code="planning_input_mismatch",
            status_code=status.HTTP_400_BAD_REQUEST,
        )


def _build_chat_input_summary(data: AIChatRequest) -> dict:
    return {
        "message_preview": data.message[:500],
        "message_length": len(data.message),
        "history_count": len(data.history),
        "context_keys": sorted((data.context or {}).keys()),
        "model_role": data.model_role,
        "language": data.language,
        "use_rag": data.use_rag,
        "rag_limit": data.rag_limit,
        "planning_enabled": data.planning_state is not None,
        "input_revision": data.input_revision if data.planning_state is not None else None,
        "is_onboarding": data.is_onboarding,
    }


# With stops already picked, "more" requests show a short list, not a full row.
MORE_WITH_PICKS = 3

# Questions the app answers with its own buttons (they send a structured answer).
# While one of these is the next question, the model's own quick replies would be
# a second, broken set of buttons, so none are offered.
STRUCTURED_QUESTIONS = frozenset({"activity_level", "travel_start_date", "prefers_quiet"})

# Appended when the model names a destination that is not in the catalog context.
UNMATCHED_DESTINATION_NOTE = (
    "\n\nI couldn't match that destination to an active "
    "Lakbay catalog entry, so I kept your current destination selection. "
    "Choose a destination from the preview or clarify the place."
)

_ADD_WORDS = re.compile(
    r"\b(add|include|put|insert|idagdag|dugang|dagdag)\b", re.IGNORECASE,
)


def _asks_to_add(message: str) -> bool:
    return _ADD_WORDS.search(message) is not None


def _state_with_destinations(state: PlanningState, ids: list[int]) -> PlanningState:
    """The state with these stops; choices tied to the old stops are cleared."""
    values = state.model_dump()
    if state.route_preferences is not None and state.route_preferences.road_access_confirmed:
        values["route_preferences"] = None
    values.update(
        selected_transport_option_ids=[],
        selected_activity_option_ids=[],
        selected_accommodation_ids=[],
        cost_allowances=[],
        transport_pricing=[],
        accommodation_pricing=[],
        age_pricing_rules=[],
        destination_ids=ids,
    )
    return PlanningState.model_validate(values)


async def _named_place_cards(
    session: AsyncSession,
    destination_ids: list[int],
    *,
    travel_mode: str,
    reason: str,
    matched_fields: list[str] | None = None,
) -> list[PlanningRecommendationItem]:
    """Selectable cards for places the traveler named, in the order given."""
    named = await AIItineraryRepository(session).list_active_destinations_by_ids(
        list(dict.fromkeys(destination_ids)),
    )
    by_id = {item.destination_id: item for item in named}
    return [
        PlanningRecommendationItem(
            destination_id=by_id[i].destination_id,
            name=by_id[i].name,
            district=by_id[i].district,
            category=by_id[i].category,
            image_url=by_id[i].image_url,
            lat=by_id[i].lat,
            lng=by_id[i].lng,
            estimated_cost=by_id[i].estimated_cost,
            score=0.0,
            matched_fields=matched_fields or ["location"],
            reasons=[reason],
            travel_mode=travel_mode,
        )
        for i in dict.fromkeys(destination_ids)
        if i in by_id
    ]


async def _add_confirmation(session: AsyncSession, destination_ids: list[int]) -> str:
    """Server-written reply after a place the traveler named was added."""
    found = await AIItineraryRepository(session).list_active_destinations_by_ids(
        list(destination_ids),
    )
    names_by_id = {item.destination_id: item.name for item in found}
    names = [names_by_id[i] for i in destination_ids if i in names_by_id]
    if not names:
        return "Added to your plan. Want to add more or start planning?"
    added = names[-1]
    count = len(names)
    stops = "stop" if count == 1 else "stops"
    return (
        f"Added {added}: that makes {count} {stops} in your plan ({', '.join(names)}). "
        "Want to add more or start planning?"
    )


async def _build_planning_chat_result(
    *,
    content: str,
    data: AIChatRequest,
    session: AsyncSession,
    route_service: RouteService | None,
    retrieved_destination_ids: set[int],
    named_destination_ids: list[int] | None = None,
    requested_locations: list[str] | None = None,
    retrieval_interest: str | None = None,
    catalog: list[tuple[int, str]] | None = None,
) -> tuple[str, AIPlanningChatResult, str]:
    assert data.planning_state is not None
    current_state = data.planning_state
    fallback_response = (
        "I couldn't safely update your plan from that response. Your current "
        "preview is shown below; try restating the change or use the preview controls."
    )
    output, rejected_fields = _parse_planning_chat_output(content)
    # Details the model guessed (never said by the traveler) are dropped, not blamed.
    unconfirmed_fields: list[str] = []
    if output is not None:
        output, unconfirmed_fields = _reject_unconfirmed_trip_details(output, data)

    # When the model ignored the JSON format but still wrote a usable answer, the
    # traveler gets that answer; nothing in the plan is changed from it.
    salvaged = _salvage_reply(content) if output is None else None
    if output is None:
        # So an unusable reply can be understood later (the traveler never sees this).
        _timing_log.warning(
            "planning chat reply not usable (salvaged=%s): %s",
            bool(salvaged), (content or "")[:500].replace("\n", " "),
        )
    update_status = "no_changes" if salvaged else "invalid_output"
    validation_status = "invalid"
    chat_response = salvaged or fallback_response
    changes_json: dict = {}
    next_state = current_state
    if output is not None:
        # The recovered output is validated before use; the run table's
        # validation-status constraint does not define a separate partial value.
        validation_status = "valid"
        chat_response = _restore_line_breaks(output.chat_response.strip())
        changes = output.state_updates.model_dump(exclude_unset=True, mode="python")
        changes_json = output.state_updates.model_dump(exclude_unset=True, mode="json")
        update_status = "no_changes"

        proposed_origin = changes.get("origin")
        if isinstance(proposed_origin, dict):
            label = proposed_origin["label"]
            current_origin = current_state.origin
            if (
                current_origin is not None
                and current_origin.label is not None
                and current_origin.label.casefold() == label.casefold()
            ):
                changes.pop("origin")
                changes_json.pop("origin", None)
            else:
                # An AI-proposed label cannot supply coordinates. Clear stale
                # coordinates when the traveler changes their origin label.
                changes["origin"] = PlanningOrigin(label=label)

        requested_destinations = changes.get("destination_ids")
        if requested_destinations is not None:
            allowed_destinations = retrieved_destination_ids | set(current_state.destination_ids)
            if not set(requested_destinations).issubset(allowed_destinations):
                changes.pop("destination_ids")
                changes_json.pop("destination_ids", None)
                update_status = "needs_clarification"
                chat_response = f"{chat_response}{UNMATCHED_DESTINATION_NOTE}"

        current_values = current_state.model_dump(mode="json")
        for field_name, value in list(changes_json.items()):
            if field_name in changes and current_values.get(field_name) == value:
                changes.pop(field_name)
                changes_json.pop(field_name)

        try:
            if changes:
                state_values = current_state.model_dump()
                if (
                    current_state.route_preferences is not None
                    and current_state.route_preferences.road_access_confirmed
                    and changes.keys() & {"origin", "destination_ids", "return_to_origin"}
                ):
                    state_values["route_preferences"] = None
                    changes_json["route_preferences"] = None
                if (
                    "destination_ids" in changes
                    and changes["destination_ids"] != current_state.destination_ids
                ):
                    # Choices and allowances belong to the old destinations.
                    state_values.update(
                        selected_transport_option_ids=[],
                        selected_activity_option_ids=[],
                        selected_accommodation_ids=[],
                        cost_allowances=[],
                        transport_pricing=[],
                        accommodation_pricing=[],
                        age_pricing_rules=[],
                    )
                next_state = PlanningState.model_validate(
                    {**state_values, **changes},
                )
                if update_status != "needs_clarification":
                    update_status = "applied"
            elif update_status != "needs_clarification":
                update_status = "no_changes"
        except ValidationError:
            next_state = current_state
            changes_json = {}
            update_status = "invalid_output"
            validation_status = "invalid"
            chat_response = fallback_response

    if output is not None and (rejected_fields or unconfirmed_fields):
        # The model's own reply may claim something that was not saved, so it is
        # replaced by a plain note and the next real question.
        chat_response = _refusal_reply(
            rejected_fields,
            unconfirmed_fields,
            origin_label=(next_state.origin.label if next_state.origin else None),
            next_question=compute_stage(next_state).next_question,
        )

    # If the traveler clearly named one catalog destination and the model did not select
    # it (cautious models often just ask questions), add it here so the plan moves on.
    resolver_matches = (
        match_destinations(data.message, catalog)
        if catalog and not next_state.destination_ids
        else []
    )
    # A question about a place ("What time does Museo Panabo open?") is not a request
    # to add it.
    asking = _looks_like_question(data.message) or (
        output is not None and output.intent in {"question", "logistics", "smalltalk"}
    )
    auto_added = (
        pick_single_destination(data.message, catalog)
        if resolver_matches and not current_state.destination_ids and not asking
        else None
    )
    if auto_added is not None:
        try:
            next_state = PlanningState.model_validate(
                {**next_state.model_dump(), "destination_ids": [auto_added.destination_id]},
            )
            changes_json["destination_ids"] = [auto_added.destination_id]
            update_status = "applied"
            chat_response = (
                f"{chat_response}\n\nI added {auto_added.name} to your plan."
            )
            resolver_matches = []
        except ValidationError:
            auto_added = None

    # Stops are already picked and the traveler names another catalog place. An explicit
    # "add" puts it in the plan; anything else offers that one place as a card. Either
    # way the place they named is never swapped for a ranking of the whole category.
    named_card_ids: list[int] = []
    named_add_done = False
    output_intent_early = output.intent if output is not None else None
    if catalog and current_state.destination_ids:
        # What the traveler had before this message: the model's own proposals (which
        # can name the wrong place) do not count as picks.
        already_picked = set(current_state.destination_ids)
        unpicked = [(i, n) for i, n in catalog if i not in already_picked]
        named_matches = match_destinations(data.message, unpicked)
        single = pick_single_destination(data.message, unpicked)
        if single is not None and _asks_to_add(data.message):
            new_ids = [*current_state.destination_ids, single.destination_id]
            try:
                next_state = _state_with_destinations(next_state, new_ids)
                changes_json["destination_ids"] = list(new_ids)
                update_status = "applied"
                named_add_done = True
                # The traveler named one place: add exactly that and write the
                # confirmation here, so the text can never disagree with the plan.
                chat_response = await _add_confirmation(session, new_ids)
            except ValidationError:
                named_card_ids = [single.destination_id]
        elif named_matches and output_intent_early not in {
            "question", "logistics", "smalltalk",
        }:
            # Offering a card is the model's call (a question stays a text answer);
            # an explicit "add" above does not depend on how the model labelled it.
            named_card_ids = [
                match.destination_id for match in named_matches[:MORE_WITH_PICKS]
            ]

    # "Is there a place to go in Panabo?" asks for places. Whatever the model labelled
    # it, the traveler gets that town's places as cards (never when something was just
    # added or a specific place was named).
    town_card_ids: list[int] = []
    town_place = ""
    if (
        not named_add_done
        and not named_card_ids
        and requested_locations
        and output_intent_early != "show_places"
        and _looks_like_browse(data.message)
        # A whole place name typed ("Museo Panabo") is about that place, not the town.
        and not any(m.full for m in match_destinations(data.message, catalog or []))
    ):
        repo = AIItineraryRepository(session)
        for place in requested_locations:
            town_card_ids = await repo.list_active_destination_ids_in_place(
                place, limit=MAX_SUGGESTIONS,
            )
            if town_card_ids:
                town_place = place
                break

    preview_started = perf_counter()
    preview = await PlanningService(session, route_service).preview(
        PlanningPreviewRequest(
            input_revision=data.input_revision,
            state=next_state,
        ),
    )
    _log_timing("planning_preview", preview_started)
    recommendations = []
    recommendation_total_candidates = 0
    recommendation_shortfall_reason = None
    output_intent = output.intent if output is not None else None
    output_place_query = output.place_query if output is not None else None
    origin_coord = (
        RouteCoordinate(
            label=next_state.origin.label,
            lat=next_state.origin.lat,
            lng=next_state.origin.lng,
        )
        if next_state.origin is not None
        and next_state.origin.lat is not None
        and next_state.origin.lng is not None
        else None
    )
    selected_modes = tuple(next_state.selected_transport_option_ids)
    travel_mode = {
        ("mode:personal_vehicle",): "driving",
        ("mode:walking",): "walking",
    }.get(selected_modes, "public_transport" if selected_modes else "driving")

    if named_add_done:
        # The traveler asked to add a named place and it was added: no cards, whatever
        # the model labelled the message, and earlier talk of other kinds must not
        # bring a ranking back.
        pass
    elif output_intent == "show_places":
        place_query = output_place_query or AIPlaceQuery()
        categories = list(place_query.categories) or (
            [retrieval_interest] if retrieval_interest else []
        )
        requested_province_raw = (place_query.province or "").strip() or None
        target_province: str | None = None
        outside_province: str | None = None
        if requested_province_raw is not None:
            target_province = canonical_province_name(requested_province_raw)
            if target_province is None:
                outside_province = requested_province_raw
        elif requested_locations:
            for loc in requested_locations:
                mapped = canonical_province_name(loc)
                if mapped is not None:
                    target_province = mapped
                    break

        if target_province is None and outside_province is None:
            wants_nearby_origin = bool(
                re.search(
                    r"\b(near\s+me|nearby|around\s+here|here|closest|in\s+my\s+city|in\s+town)\b",
                    data.message,
                    flags=re.IGNORECASE,
                )
            )
            if wants_nearby_origin:
                if origin_coord is not None:
                    target_province = province_for_destination(
                        origin_coord.lat,
                        origin_coord.lng,
                        district=origin_coord.label,
                    )
                elif next_state.origin is not None and next_state.origin.label:
                    target_province = canonical_province_name(next_state.origin.label)

        if outside_province is not None:
            nearby = nearest_provinces(
                lat=origin_coord.lat if origin_coord is not None else None,
                lng=origin_coord.lng if origin_coord is not None else None,
            )
            recommendation_shortfall_reason = (
                f"{outside_province} is outside the Davao Region (Region XI). "
                f"Closest Region XI provinces to explore: {', '.join(nearby[:3])}."
            )
            chat_response = recommendation_shortfall_reason
        else:
            ranking_started = perf_counter()
            place_result = await RecommendationService(session).rank_place_query(
                categories=categories,
                province=target_province,
                origin=origin_coord,
                travel_mode=travel_mode,
                total_budget=next_state.total_budget,
                budget_scope=next_state.budget_scope,
                traveler_count=next_state.traveler_count,
                adult_count=next_state.adult_count,
                child_ages=next_state.child_ages,
                day_count=next_state.day_count,
                limit=place_query.limit,
                osrm_client=route_service.osrm_client if route_service is not None else None,
            )
            _log_timing("recommendation_ranking", ranking_started)
            picked_now = set(next_state.destination_ids)
            recommendations = [
                planning_recommendation_from_top_place(item)
                for item in place_result.items
                if item.destination_id not in picked_now
            ][: (MORE_WITH_PICKS if picked_now else MAX_SUGGESTIONS)]
            recommendation_total_candidates = place_result.total_candidates
            recommendation_shortfall_reason = place_result.shortfall_reason
            if recommendation_shortfall_reason is not None and not recommendations:
                # With no cards there is nothing to introduce, so say why. With
                # some cards the model's reply stays and the reason is a note.
                chat_response = recommendation_shortfall_reason
    elif town_card_ids:
        recommendations = await _named_place_cards(
            session,
            town_card_ids,
            travel_mode=travel_mode,
            reason=f"In {town_place.title()}.",
        )
        recommendation_total_candidates = len(recommendations)
    elif output_intent in {"question", "logistics", "smalltalk"}:
        # Q&A, logistics, and small talk stay concise text replies without card dumps.
        # So does a named place that was just added: the traveler got what they asked
        # for, and an earlier interest in the chat must not bring other cards back.
        pass
    elif named_card_ids:
        recommendations = await _named_place_cards(
            session,
            named_card_ids,
            travel_mode=travel_mode,
            reason="Matches the place you named.",
        )
        recommendation_total_candidates = len(recommendations)
    else:
        # If the model did not record an interest the traveler stated, use the one the
        # catalog retrieval detected in the message so the Top 5 cards still appear.
        ranking_interests = list(next_state.interests) or (
            [retrieval_interest] if retrieval_interest else []
        )
        if not next_state.destination_ids and not ranking_interests:
            # Without interests there is nothing to rank. If the traveler named a place the
            # catalog matched, offer those places as selectable cards instead of leaving the
            # plan with no way to choose a destination.
            card_ids = [match.destination_id for match in resolver_matches] or (
                list(named_destination_ids or []) if requested_locations else []
            )
            if card_ids:
                recommendations = await _named_place_cards(
                    session,
                    list(dict.fromkeys(card_ids))[:MAX_SUGGESTIONS],
                    travel_mode=travel_mode,
                    reason=(
                        f"Matches the place you named: {', '.join(requested_locations)}"
                        if requested_locations
                        else "Matches the place you named."
                    ),
                    matched_fields=["location"],
                )
                recommendation_total_candidates = len(recommendations)
            if not recommendations:
                recommendation_shortfall_reason = (
                    "No travel interests were supplied, so there is no preference match to rank."
                )
        elif not next_state.destination_ids or retrieval_interest:
            # With stops already chosen, only rank when this message asked for more of an
            # interest, and never offer a place that is already in the plan.
            already_selected = set(next_state.destination_ids)
            if already_selected:
                ranking_interests = [retrieval_interest]
            ranking_started = perf_counter()
            top_places = await RecommendationService(session).rank_top_places(
                data=TopPlacesRequest(
                    interests=ranking_interests,
                    origin=origin_coord,
                    # Catalog fare choices mean the traveler is commuting; no choice
                    # yet is ranked by car.
                    travel_mode=travel_mode,
                    total_budget=next_state.total_budget,
                    budget_scope=next_state.budget_scope,
                    traveler_count=next_state.traveler_count,
                    adult_count=next_state.adult_count,
                    child_ages=next_state.child_ages,
                    day_count=next_state.day_count,
                    activity_level=next_state.activity_level,
                    travel_start_date=next_state.travel_start_date,
                    prefers_quiet=bool(next_state.prefers_quiet),
                    priority_order=list(next_state.priority_order),
                    fill_to_limit=True,
                ),
                osrm_client=route_service.osrm_client if route_service is not None else None,
            )
            _log_timing("recommendation_ranking", ranking_started)
            recommendations = [
                planning_recommendation_from_top_place(item)
                for item in top_places.items
                if item.destination_id not in already_selected
            ][: (MORE_WITH_PICKS if already_selected else MAX_SUGGESTIONS)]
            recommendation_total_candidates = top_places.total_candidates
            recommendation_shortfall_reason = top_places.shortfall_reason
            if already_selected:
                # The plan already has stops, so a thin result is not worth replacing the
                # model's reply with a shortfall message.
                recommendation_shortfall_reason = None
            if recommendation_shortfall_reason is not None and not recommendations:
                # Only when there are no cards: the catalog and route checks are
                # authoritative over model prose. With cards, the reason stays a note.
                chat_response = recommendation_shortfall_reason
    chat_response = _align_text_with_cards(
        chat_response,
        card_ids={item.destination_id for item in recommendations},
        allowed_ids=set(next_state.destination_ids)
        | {match.destination_id for match in (match_destinations(data.message, catalog or []))},
        catalog=catalog or [],
        origin_label=(next_state.origin.label if next_state.origin else None),
    )
    return (
        chat_response,
        AIPlanningChatResult(
            input_revision=data.input_revision,
            intent=output_intent,
            place_query=output_place_query,
            suggested_replies=(
                []
                if output is None or _next_question_is_structured(next_state)
                else output.suggested_replies
            ),
            state_updates=changes_json,
            update_status=update_status,
            preview=preview,
            recommendations=recommendations,
            recommendation_total_candidates=recommendation_total_candidates,
            recommendation_shortfall_reason=recommendation_shortfall_reason,
            conversation=compute_stage(next_state).as_prompt_payload(),
        ),
        validation_status,
    )


def _parse_trip_draft(content: str) -> dict | None:
    """The draft JSON, with off-region or unusable stop coordinates cleared."""
    try:
        draft = json.loads(_strip_json_fence(content))
    except (TypeError, ValueError):
        return None
    if not isinstance(draft, dict) or not str(draft.get("reply") or "").strip():
        return None
    days = draft.get("days")
    if not isinstance(days, list):
        draft["days"] = []
        draft["should_create_itinerary"] = False
        return draft
    for day in days:
        activities = day.get("activities") if isinstance(day, dict) else None
        for activity in activities if isinstance(activities, list) else []:
            if not isinstance(activity, dict):
                continue
            lat, lng = activity.get("lat"), activity.get("lng")
            numeric = (
                isinstance(lat, (int, float)) and isinstance(lng, (int, float))
                and not isinstance(lat, bool) and not isinstance(lng, bool)
            )
            # The Region XI outline, not a rectangle: a box also covers parts
            # of Cotabato, Bukidnon and Caraga.
            inside = numeric and region_status(lat, lng) == "inside"
            if not inside:
                # The app places a stop without coordinates by name instead of
                # pinning it somewhere wrong (or in the sea).
                activity["lat"] = None
                activity["lng"] = None
    return draft


_QUESTION_START = re.compile(
    r"^\s*(what|when|where|which|who|whom|whose|why|how|is|are|was|were|does|do|did|"
    r"can|could|will|would|should|may|might|unsa|asa|kanus-a|kanusa|pila|ngano|ano|"
    r"saan|kailan|magkano|paano|sino|bakit)\b",
    re.IGNORECASE,
)


def _looks_like_question(message: str) -> bool:
    text = message.strip()
    return text.endswith("?") or _QUESTION_START.match(text) is not None


_CHAT_RESPONSE_FIELD = re.compile(
    r'"chat_*response"\s*:\s*"((?:[^"\\]|\\.)*)"', re.DOTALL,
)


_BROWSE_PATTERNS = (
    re.compile(
        r"\b(places?|spots?|attractions?|things?|something)\b.{0,25}"
        r"\b(to go|to visit|to see|to do|worth)\b",
        re.IGNORECASE,
    ),
    re.compile(r"\bwhat('?s| is| are)?\b.{0,30}\b(to do|to see|to visit)\b", re.IGNORECASE),
    re.compile(r"\bwhere (can|should|to)\b.{0,12}\bgo\b", re.IGNORECASE),
    re.compile(r"\bwhat\b.{0,12}\b(can|should|could)\b.{0,8}\b(do|see|visit)\b", re.IGNORECASE),
    re.compile(r"\b(any|got|have)\b.{0,20}\b(places?|spots?|attractions?)\b", re.IGNORECASE),
    re.compile(
        r"\b(unsa|asa|saan)\b.{0,20}\b(nindot|maganda|pasyalan|bisitahon)\b",
        re.IGNORECASE,
    ),
)


def _looks_like_browse(message: str) -> bool:
    """A request to be shown places (not a question about one named place)."""
    return any(pattern.search(message) for pattern in _BROWSE_PATTERNS)


_FROM_DAVAO = re.compile(r"\bfrom\s+davao\s+city\b", re.IGNORECASE)
_SENTENCE_END = re.compile(r"(?<=[.!?])\s+")


def _align_text_with_cards(
    reply: str,
    *,
    card_ids: set[int],
    allowed_ids: set[int],
    catalog: list[tuple[int, str]],
    origin_label: str | None,
) -> str:
    """Keeps the text in step with the cards and with the traveler's start place.

    With cards on screen, a sentence that names a catalog place that is not a card
    (and not picked or asked about) is dropped, so the text never points at places
    the traveler cannot see. A sentence that gives a route "from Davao City" is
    dropped when the traveler starts somewhere else.
    """
    if not reply.strip():
        return reply
    not_davao = bool(origin_label) and "davao city" not in (origin_label or "").lower()
    if not card_ids and not not_davao:
        return reply
    visible = card_ids | allowed_ids

    def stray_names(sentence: str) -> bool:
        words = set(_tokens(sentence))
        matched: dict[int, frozenset] = {}
        for local_id, name in catalog:
            distinctive = _distinctive(name)
            if distinctive and all(word in words for word in distinctive):
                matched[local_id] = frozenset(distinctive)
        # "Dahican Beach" is part of "Dahican Surf Resort": only the longer name counts.
        named = [
            i for i, d in matched.items()
            if not any(d < other for j, other in matched.items() if j != i)
        ]
        # Places that share the same name words cannot be told apart: the sentence
        # is fine when any of them is visible.
        groups: dict[frozenset, list[int]] = {}
        for i in named:
            groups.setdefault(matched[i], []).append(i)
        return any(all(i not in visible for i in members) for members in groups.values())

    kept_lines: list[str] = []
    changed = False
    for line in reply.split("\n"):
        kept: list[str] = []
        for sentence in _SENTENCE_END.split(line):
            drop = (bool(card_ids) and stray_names(sentence)) or (
                not_davao and bool(_FROM_DAVAO.search(sentence))
            )
            if drop:
                changed = True
            else:
                kept.append(sentence)
        kept_lines.append(" ".join(kept))
    if not changed:
        return reply
    text = "\n".join(kept_lines).strip()
    text = re.sub(r"\n{3,}", "\n\n", text)
    if text:
        return text
    if card_ids:
        return "Here are some places that match what you asked for."
    return f"I don't have travel times from {origin_label} for that yet."


_CLAIMS_A_CHANGE = re.compile(
    r"\b(i(?:'ve|\s+have)?\s+(?:added|set|updated|saved|changed|chose|selected|booked|removed)"
    r"|(?:added|updated|saved|booked|removed)\s+(?:the|your|it|that|them|those)\b"
    r"|(?:has|have)\s+been\s+(?:added|updated|saved|booked|removed))",
    re.IGNORECASE,
)


def _salvage_reply(content: str) -> str | None:
    """The traveler-facing text from a model reply that is not valid planning JSON.

    Broken or cut-off JSON still holds a "chat_response" string; a plain-text reply
    is the answer itself. Anything else (empty, a bare JSON object, code) gives None
    and the caller keeps the generic fallback.
    """
    text = (content or "").strip()
    if not text:
        return None
    candidate: str | None = None
    try:
        loaded = json.loads(_strip_json_fence(text))
    except (TypeError, ValueError):
        loaded = None
    if isinstance(loaded, dict):
        if "chat_response" in loaded:
            # Valid JSON that was still refused (for example a field the model may
            # not set): its text may claim changes that were never made.
            return None
        # A misspelt key such as "chat__response": the text is still the answer.
        key = next((k for k in loaded if re.fullmatch(r"chat_*response", str(k))), None)
        value = loaded.get(key) if key else None
        candidate = value.strip() if isinstance(value, str) else None
    elif loaded is not None:
        return None
    else:
        field = _CHAT_RESPONSE_FIELD.search(text)
        if field is not None:
            try:
                candidate = json.loads(f'"{field.group(1)}"').strip()
            except ValueError:
                return None
        elif text[0] not in "{[`" and '"state_updates"' not in text and len(text) <= 1500:
            candidate = text
    if not candidate:
        return None
    # Nothing was saved, so never show text that says something was.
    if _CLAIMS_A_CHANGE.search(candidate):
        return None
    return _restore_line_breaks(candidate)


def _restore_line_breaks(text: str) -> str:
    """Some models double-escape line breaks, so travelers would see a literal "\n"."""
    return text.replace("\\n", "\n")


def _strip_json_fence(content: str) -> str:
    value = content.strip()
    if value.startswith("```") and value.endswith("```"):
        value = value.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
    elif "```" in value:
        fenced = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", value, flags=re.DOTALL)
        if fenced:
            return fenced.group(1).strip()
    if not value.startswith("{") and "{" in value and "}" in value:
        start = value.find("{")
        end = value.rfind("}")
        if end > start:
            candidate = value[start : end + 1].strip()
            if '"chat_response"' in candidate:
                return candidate
    return value


def _parse_planning_chat_output(
    content: str,
) -> tuple[AIPlanningChatOutput | None, list[str]]:
    """Retain valid allowlisted fields when a sibling field has bad shape."""
    cleaned = _strip_json_fence(content)
    try:
        return AIPlanningChatOutput.model_validate_json(cleaned), []
    except ValidationError:
        pass

    try:
        raw = json.loads(cleaned)
    except (TypeError, ValueError):
        return None, []
    required = {"chat_response"}
    optional = {"state_updates", "intent", "suggested_replies", "place_query"}
    if not isinstance(raw, dict) or not required <= set(raw) <= required | optional:
        return None, []
    updates = raw.get("state_updates", {})
    if updates is None:
        updates = {}
    if not isinstance(updates, dict):
        return None, []
    allowed_fields = set(AIPlanningStateUpdates.model_fields)
    if set(updates) - allowed_fields:
        # Unsupported selections are never silently accepted or ignored.
        return None, []

    valid_updates: dict = {}
    rejected_fields: list[str] = []
    for field_name, value in updates.items():
        try:
            validated = AIPlanningStateUpdates.model_validate({field_name: value})
        except ValidationError:
            rejected_fields.append(field_name)
            continue
        valid_updates[field_name] = validated.model_dump(
            exclude_unset=True, mode="python",
        )[field_name]
    if not rejected_fields:
        return None, []
    try:
        output = AIPlanningChatOutput.model_validate({
            "chat_response": raw["chat_response"],
            "state_updates": valid_updates,
            "intent": raw.get("intent"),
            "place_query": raw.get("place_query"),
            "suggested_replies": raw.get("suggested_replies", []),
        })
    except ValidationError:
        return None, []
    return output, rejected_fields


_NIGHT_WORDS = {
    "zero": 0,
    "one": 1,
    "two": 2,
    "three": 3,
    "four": 4,
    "five": 5,
    "six": 6,
    "seven": 7,
    "eight": 8,
    "nine": 9,
    "ten": 10,
}
_NIGHT_NUMBER = r"\d+|zero|one|two|three|four|five|six|seven|eight|nine|ten"


def _number_from_text(value: str) -> int:
    return _NIGHT_WORDS.get(value.casefold(), int(value) if value.isdigit() else -1)


def _confirmed_night_count(data: AIChatRequest) -> int | None:
    message = data.message.casefold().strip()
    if re.search(
        r"\b(?:same[ -]?day|no overnight|without overnight|no nights?|"
        r"not staying overnight|won't stay overnight|will not stay overnight)\b",
        message,
    ):
        return 0
    if re.search(r"\bday[ -]?trip\b", message) and not re.search(
        r"\b(?:[2-9]|[1-9]\d+|two|three|four|five|six|seven|eight|nine|ten)[ -]?day[ -]?trip\b",
        message,
    ):
        return 0
    matches = re.findall(
        rf"\b({_NIGHT_NUMBER})\s*(?:nights?|overnights?(?:\s+stays?)?)\b",
        message,
    )
    if matches:
        counts = {_number_from_text(value) for value in matches}
        return counts.pop() if len(counts) == 1 else None
    if data.history and data.history[-1].role == "assistant":
        question = data.history[-1].content.casefold()
        if re.search(r"\b(?:nights?|overnights?)\b", question):
            bare_number = re.fullmatch(rf"\s*({_NIGHT_NUMBER})\s*", message)
            if bare_number:
                return _number_from_text(bare_number.group(1))
    return None


def _confirmed_return_to_origin(data: AIChatRequest) -> bool | None:
    message = data.message.casefold().strip()
    no_return_pattern = (
        r"\b(?:one[ -]?way|no return|no round[ -]?trip|not return(?:ing)?|"
        r"don't return|won't return|will not return|not going back|"
        r"don't go back|without (?:a )?return)\b"
    )
    says_no_return = re.search(no_return_pattern, message)
    says_return = re.search(
        r"\b(?:round[ -]?trip|return(?:ing)? (?:to|back|fare|bus|trip)|"
        r"go(?:ing)? back|back to|will return|include (?:the )?return fare)\b",
        re.sub(no_return_pattern, "", message),
    )
    if says_no_return and says_return:
        return None
    if says_no_return:
        return False
    if says_return:
        return True
    if data.history and data.history[-1].role == "assistant":
        question = data.history[-1].content.casefold()
        if re.search(r"\b(?:return|round[ -]?trip|back to)\b", question):
            if re.fullmatch(r"(?:yes|yes please|yep|sure)", message):
                return True
            if re.fullmatch(r"(?:no|no thanks|no thank you|nope)", message):
                return False
    return None


def _reject_unconfirmed_trip_details(
    output: AIPlanningChatOutput,
    data: AIChatRequest,
) -> tuple[AIPlanningChatOutput, list[str]]:
    updates = output.state_updates.model_dump(exclude_unset=True, mode="python")
    rejected: list[str] = []
    confirmed_values = {
        "night_count": _confirmed_night_count(data),
        "return_to_origin": _confirmed_return_to_origin(data),
    }
    for field_name, confirmed_value in confirmed_values.items():
        if field_name not in updates:
            continue
        if confirmed_value is not None and updates[field_name] == confirmed_value:
            continue
        if confirmed_value is None and data.planning_state is not None and updates[field_name] == getattr(
            data.planning_state, field_name,
        ):
            continue
        updates.pop(field_name)
        rejected.append(field_name)
    if not rejected:
        return output, []
    return output.model_copy(update={
        "state_updates": AIPlanningStateUpdates.model_validate(updates),
    }), rejected


def _next_question_is_structured(state: PlanningState) -> bool:
    missing = compute_stage(state).missing_details
    return bool(missing) and missing[0] in STRUCTURED_QUESTIONS


def _refusal_reply(
    shape_fields: list[str],
    unconfirmed_fields: list[str],
    *,
    origin_label: str | None,
    next_question: str | None,
) -> str:
    """What to say when some proposed details were not saved.

    A detail the model guessed is simply not assumed. A detail the traveler gave
    that could not be saved is named, with a way to set it. Either way the
    conversation moves on to the next question the plan really needs.
    """
    labels = {
        "origin": "starting place",
        "destination_ids": "destination",
        "total_budget": "budget",
        "budget_scope": "budget scope",
        "traveler_count": "traveler count",
        "day_count": "day count",
        "interests": "travel interests",
    }
    parts: list[str] = []
    if unconfirmed_fields:
        assumed = []
        if "night_count" in unconfirmed_fields:
            assumed.append("an overnight stay")
        if "return_to_origin" in unconfirmed_fields:
            assumed.append(f"whether you'll return to {origin_label or 'your starting place'}")
        parts.append(
            f"I haven't assumed {' or '.join(assumed)}; you can set that in the plan review."
        )
    if shape_fields:
        names = ", ".join(labels.get(field, field.replace("_", " ")) for field in shape_fields)
        parts.append(
            f"I couldn't save your {names}. Please try again or set it in the plan review."
        )
    if next_question:
        parts.append(next_question)
    return " ".join(parts)


def _build_run_result(
    *,
    run: AIGenerationRun,
    options: list,
) -> AIModelRunResult:
    return AIModelRunResult(
        ai_generation_run_id=run.ai_generation_run_id,
        model_role=run.model_role,
        model_id=run.model_id,
        status=run.status,
        validation_status=run.validation_status,
        response_time_ms=run.response_time_ms,
        prompt_tokens=run.prompt_tokens,
        completion_tokens=run.completion_tokens,
        total_tokens=run.total_tokens,
        error_message=run.error_message,
        options=options,
    )


def _apply_strict_budget_filter(
    *,
    options: list,
    total_budget: Decimal,
) -> list:
    """Keep only within-budget AI options, or the cheapest fallback if all exceed budget."""
    within_budget = [
        option
        for option in options
        if not option.is_over_budget and Decimal(option.estimated_total_cost) <= total_budget
    ]
    if within_budget:
        return sorted(within_budget, key=lambda option: option.option_number)

    cheapest = min(
        options,
        key=lambda option: (Decimal(option.estimated_total_cost), option.option_number),
    )
    warning = (
        f"All generated options exceeded the PHP {total_budget:.2f} budget; "
        "showing the lowest-cost option for adjustment."
    )
    existing_warnings = list(cheapest.quality_warnings)
    if warning not in existing_warnings:
        existing_warnings.append(warning)
    return [cheapest.model_copy(update={"quality_warnings": existing_warnings})]


def _elapsed_ms(started_at: float) -> int:
    return int((perf_counter() - started_at) * 1000)


def _sum_tokens(first: int | None, second: int | None) -> int | None:
    if first is None and second is None:
        return None
    return (first or 0) + (second or 0)


def _classify_groq_error(exc: GroqClientError) -> str:
    if isinstance(exc, GroqRateLimitError):
        return "rate_limit"
    msg = exc.message.lower()
    if "unavailable" in msg or "rejected" in msg:
        return "model_unavailable"
    if "server error" in msg:
        return "provider_server_error"
    return "provider_request_failed"

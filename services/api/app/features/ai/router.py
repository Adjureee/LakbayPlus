from typing import Annotated

from fastapi import APIRouter, Depends, Request, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.dependencies import get_current_user, get_optional_current_user
from app.core.exceptions import LakbayAPIError
from app.db.session import get_db_session
from app.features.ai.schemas import (
    AIChatRequest,
    AIChatResponse,
    AIItineraryGenerateRequest,
    AIItineraryGenerateResponse,
    AITripDraftRequest,
    AITripDraftResponse,
)
from app.features.ai.service import AIItineraryService
from app.features.planning.dependencies import get_planning_route_limiter
from app.features.routes.service import RouteService
from app.features.users.models import User
from app.integrations.groq.client import GroqClient, get_groq_client
from app.integrations.osrm.client import get_osrm_client

router = APIRouter(prefix="/ai", tags=["ai"])


def get_ai_chat_route_service(
    data: AIChatRequest,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    current_user: Annotated[User, Depends(get_current_user)],
) -> RouteService | None:
    state = data.planning_state
    if state is None:
        return None
    needs_candidate_routes = bool(
        state.origin is not None
        and state.origin.lat is not None
        and state.origin.lng is not None
        and state.selected_transport_option_ids in (
            ["mode:personal_vehicle"], ["mode:walking"],
        )
    )
    if state.route_preferences is None and not needs_candidate_routes:
        return None
    get_planning_route_limiter().check(current_user.user_id)
    return RouteService(session, get_osrm_client())


def get_ai_itinerary_route_service(
    data: AIItineraryGenerateRequest,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    current_user: Annotated[User, Depends(get_current_user)],
) -> RouteService | None:
    state = data.planning_state
    if state is None or state.route_preferences is None:
        return None
    get_planning_route_limiter().check(current_user.user_id)
    return RouteService(session, get_osrm_client())


@router.post(
    "/itineraries/generate",
    response_model=AIItineraryGenerateResponse,
    status_code=status.HTTP_200_OK,
    summary="Generate AI itinerary drafts",
    description=(
        "Protected endpoint that uses selected catalog destinations and optional "
        "rate rows to ask a configured Groq model for structured itinerary draft "
        "options. The response is validated before it is returned and no permanent "
        "trip is created in this phase."
    ),
)
async def generate_itinerary(
    data: AIItineraryGenerateRequest,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    current_user: Annotated[User, Depends(get_current_user)],
    groq_client: Annotated[GroqClient, Depends(get_groq_client)],
    route_service: Annotated[RouteService | None, Depends(get_ai_itinerary_route_service)],
) -> AIItineraryGenerateResponse:
    return await AIItineraryService(session, groq_client, route_service).generate_itinerary(
        user=current_user,
        data=data,
    )


@router.post(
    "/chat",
    response_model=AIChatResponse,
    status_code=status.HTTP_200_OK,
    summary="Chat with Lakbay AI",
    description=(
        "Protected free-text assistant endpoint. It sends the user's message, "
        "optional conversation history, and optional context to the configured "
        "Groq model and returns a natural-language assistant response. When "
        "planning_state is supplied, it also returns validated state updates and "
        "a recalculated stateless planning preview."
    ),
)
async def chat(
    data: AIChatRequest,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    current_user: Annotated[User, Depends(get_current_user)],
    groq_client: Annotated[GroqClient, Depends(get_groq_client)],
    route_service: Annotated[RouteService | None, Depends(get_ai_chat_route_service)],
) -> AIChatResponse:
    return await AIItineraryService(session, groq_client, route_service).chat(
        user=current_user,
        data=data,
    )


def guest_client_key(request: Request) -> str:
    """Identify a signed-out client for rate limiting.

    Behind Render's proxy the client address is the first X-Forwarded-For
    entry. It can be spoofed, so a shared daily cap also bounds guest usage.
    """
    forwarded = request.headers.get("x-forwarded-for", "")
    first = forwarded.split(",")[0].strip()
    if first:
        return first[:64]
    return request.client.host if request.client else "unknown"


@router.post(
    "/chat/guest",
    response_model=AIChatResponse,
    status_code=status.HTTP_200_OK,
    summary="Chat with Lakbay AI without signing in",
    description=(
        "Public, rate-limited version of /ai/chat for signed-out travelers, so "
        "the mobile app never ships an AI provider key. Limits are per client "
        "address with a shared daily cap. Road routes for suggestion cards are "
        "not calculated for guests."
    ),
)
async def guest_chat(
    data: AIChatRequest,
    request: Request,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    groq_client: Annotated[GroqClient, Depends(get_groq_client)],
) -> AIChatResponse:
    if not get_settings().guest_ai_chat_enabled:
        raise LakbayAPIError(
            "Sign in to chat with Lakbay AI.",
            code="guest_ai_chat_disabled",
            status_code=status.HTTP_403_FORBIDDEN,
        )
    # Guests may not pick a costlier model role or skip the fallback chain.
    data = data.model_copy(update={"model_role": "default", "allow_fallback": True})
    return await AIItineraryService(session, groq_client, None).chat(
        user=None,
        data=data,
        guest_key=guest_client_key(request),
    )


@router.post(
    "/trip-draft",
    response_model=AITripDraftResponse,
    status_code=status.HTTP_200_OK,
    summary="Draft a trip from a free-text request",
    description=(
        "Quick structured trip draft for onboarding and prompt-to-trip flows. "
        "Works signed in (user AI limits) or as a guest (per-client guest limits). "
        "Drafts are suggestions; /ai/itineraries/generate builds validated ones."
    ),
)
async def trip_draft(
    data: AITripDraftRequest,
    request: Request,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    current_user: Annotated[User | None, Depends(get_optional_current_user)],
    groq_client: Annotated[GroqClient, Depends(get_groq_client)],
) -> AITripDraftResponse:
    if current_user is None and not get_settings().guest_ai_chat_enabled:
        raise LakbayAPIError(
            "Sign in to use Lakbay AI.",
            code="guest_ai_chat_disabled",
            status_code=status.HTTP_403_FORBIDDEN,
        )
    return await AIItineraryService(session, groq_client, None).trip_draft(
        user=current_user,
        data=data,
        guest_key=None if current_user is not None else guest_client_key(request),
    )

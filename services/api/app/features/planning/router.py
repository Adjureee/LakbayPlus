from typing import Annotated

from fastapi import APIRouter, Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import get_current_user, get_optional_current_user
from app.db.session import get_db_session
from app.features.planning.dependencies import (
    get_optional_draft_route_service,
    get_planning_route_service,
)
from app.features.planning.schemas import (
    PlanningDraftRequest,
    PlanningDraftResponse,
    PlanningFeedbackRequest,
    PlanningFeedbackResponse,
    PlanningPreviewRequest,
    PlanningPreviewResponse,
)
from app.features.planning.service import PlanningService
from app.features.planning.timeline_schemas import TimelineRequest, TimelineResponse
from app.features.planning.timeline_service import build_timeline_response
from app.features.users.models import User
from app.features.routes.service import RouteService


router = APIRouter(prefix="/planning", tags=["planning"])


@router.post(
    "/preview",
    response_model=PlanningPreviewResponse,
    summary="Preview travel choices, expenses, routes, and fuel",
    description=(
        "Returns active catalog choices and retained planning state without saving a trip. "
        "Returns itemized estimates from explicit allowances and catalog prices with "
        "labeled charging assumptions. Missing required costs keep the budget partial. "
        "Optional route preferences add journey summaries and disclosed fuel estimates. "
        "Straight-line fallbacks and unresolved transport connections remain visible."
    ),
)
async def preview_planning(
    data: PlanningPreviewRequest,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    current_user: Annotated[User, Depends(get_current_user)],
    route_service: Annotated[RouteService | None, Depends(get_planning_route_service)],
) -> PlanningPreviewResponse:
    return await PlanningService(session, route_service).preview(data)


@router.post(
    "/feedback",
    response_model=PlanningFeedbackResponse,
    summary="Evaluate a planning preview before saving",
    description=(
        "Returns advisory budget, route, pacing, activity-load, and child-suitability "
        "findings with the underlying stateless preview. It does not save a trip."
    ),
)
async def feedback_planning(
    data: PlanningFeedbackRequest,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    current_user: Annotated[User, Depends(get_current_user)],
    route_service: Annotated[RouteService | None, Depends(get_planning_route_service)],
) -> PlanningFeedbackResponse:
    return await PlanningService(session, route_service).feedback(data)


@router.post(
    "/draft",
    response_model=PlanningDraftResponse,
    summary="Build a deterministic itinerary draft without AI",
    description=(
        "Builds up to two structured catalog itinerary options from active destinations, "
        "route order, visit durations, and catalog prices without calling an AI model. "
        "Available to both guests and signed-in travelers."
    ),
)
async def draft_planning(
    data: PlanningDraftRequest,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    current_user: Annotated[User | None, Depends(get_optional_current_user)],
    route_service: Annotated[RouteService | None, Depends(get_optional_draft_route_service)],
) -> PlanningDraftResponse:
    del current_user  # Both guests and signed-in travelers may build catalog drafts.
    return await PlanningService(session, route_service).draft(data)


@router.post(
    "/timeline",
    response_model=TimelineResponse,
    summary="Build a day-by-day timeline from the traveler's picks",
    description=(
        "Builds one timeline in code, without an AI model, from the selected places in "
        "route order: travel legs, visit lengths, opening hours and last admission, meals, "
        "buffers and the return. Unknown travel times and costs stay unknown and the "
        "times after them are provisional; picks are never dropped or reordered, and a "
        "pick that does not fit is reported as a conflict with choices. Each check is "
        "passed, failed or cannot verify. Send `previous` and `pins` to revise: the "
        "response lists what changed. Nothing is saved. Guests and signed-in travelers."
    ),
)
async def timeline_planning(
    data: TimelineRequest,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    current_user: Annotated[User | None, Depends(get_optional_current_user)],
    route_service: Annotated[RouteService | None, Depends(get_optional_draft_route_service)],
) -> TimelineResponse:
    del current_user  # Both guests and signed-in travelers may build a timeline.
    return await build_timeline_response(session, route_service, data)

"""Commute directions: public for travelers, admin for editing and drafting."""

from typing import Annotated

from fastapi import APIRouter, Depends, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import require_admin
from app.db.session import get_db_session
from app.features.commute.schemas import (
    CommuteDraftRequest,
    CommuteDraftResponse,
    CommuteOptionsResponse,
    CommuteRouteInput,
    CommuteRouteResponse,
)
from app.features.commute.service import CommuteService
from app.features.users.models import User
from app.integrations.groq.client import GroqClient, get_groq_client

router = APIRouter(prefix="/destinations/{destination_id}/commute", tags=["commute"])
admin_router = APIRouter(prefix="/admin", tags=["admin commute"])


@router.get(
    "",
    response_model=CommuteOptionsResponse,
    summary="Public-transport ways to reach a place",
    description=(
        "Public endpoint. Returns only routes an admin has verified, each with its "
        "ordered steps and totals worked out from them. Missing times or fares stay "
        "empty and the totals say whether they are complete."
    ),
)
async def get_commute_options(
    destination_id: int,
    session: Annotated[AsyncSession, Depends(get_db_session)],
) -> CommuteOptionsResponse:
    return await CommuteService(session).public_options(destination_id)


@admin_router.get(
    "/destinations/{destination_id}/commute",
    response_model=CommuteOptionsResponse,
    summary="List every commute route of a place, including unverified ones",
)
async def admin_list_commute(
    destination_id: int,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    admin: Annotated[User, Depends(require_admin)],
) -> CommuteOptionsResponse:
    _ = admin
    return await CommuteService(session).admin_options(destination_id)


@admin_router.post(
    "/destinations/{destination_id}/commute",
    response_model=CommuteRouteResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Add a commute route to a place",
)
async def admin_create_commute(
    destination_id: int,
    data: CommuteRouteInput,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    admin: Annotated[User, Depends(require_admin)],
) -> CommuteRouteResponse:
    return await CommuteService(session).create(destination_id, data, admin)


@admin_router.put(
    "/commute/{commute_route_id}",
    response_model=CommuteRouteResponse,
    summary="Replace a commute route and its steps (also verifies or unverifies it)",
)
async def admin_replace_commute(
    commute_route_id: int,
    data: CommuteRouteInput,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    admin: Annotated[User, Depends(require_admin)],
) -> CommuteRouteResponse:
    return await CommuteService(session).replace(commute_route_id, data, admin)


@admin_router.delete(
    "/commute/{commute_route_id}",
    response_model=CommuteRouteResponse,
    summary="Switch a commute route off (it is kept, hidden from travelers)",
)
async def admin_deactivate_commute(
    commute_route_id: int,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    admin: Annotated[User, Depends(require_admin)],
) -> CommuteRouteResponse:
    _ = admin
    return await CommuteService(session).deactivate(commute_route_id)


@admin_router.post(
    "/destinations/{destination_id}/commute/draft",
    response_model=CommuteDraftResponse,
    summary="Draft commute steps from the place's how-to-get-there notes",
    description=(
        "Admin only. Asks the AI to turn the notes into structured steps, using only "
        "what the notes say. Nothing is saved and nothing is verified: an admin "
        "reviews the draft and saves it."
    ),
)
async def admin_draft_commute(
    destination_id: int,
    data: CommuteDraftRequest,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    admin: Annotated[User, Depends(require_admin)],
    groq_client: Annotated[GroqClient, Depends(get_groq_client)],
) -> CommuteDraftResponse:
    return await CommuteService(session).draft(destination_id, data, admin, groq_client)

"""Admin API endpoints for managing sea ports and boat connections (sea links)."""

from typing import Annotated

from fastapi import APIRouter, Depends, Query, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.dependencies import require_admin
from app.db.session import get_db_session
from app.features.sea_links.schemas import (
    SeaLinkCreate,
    SeaLinkResponse,
    SeaLinkUpdate,
    SeaPortCreate,
    SeaPortResponse,
    SeaPortUpdate,
)
from app.features.sea_links.service import SeaLinkAdminService
from app.features.users.models import User

admin_router = APIRouter(prefix="/admin", tags=["admin sea links"])


@admin_router.get(
    "/sea-ports",
    response_model=list[SeaPortResponse],
    summary="List sea ports for admin review and editing",
)
async def list_sea_ports(
    session: Annotated[AsyncSession, Depends(get_db_session)],
    admin: Annotated[User, Depends(require_admin)],
    include_inactive: bool = Query(default=True),
) -> list[SeaPortResponse]:
    _ = admin
    return await SeaLinkAdminService(session).list_ports(include_inactive=include_inactive)


@admin_router.post(
    "/sea-ports",
    response_model=SeaPortResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Create a sea port terminal",
)
async def create_sea_port(
    data: SeaPortCreate,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    admin: Annotated[User, Depends(require_admin)],
) -> SeaPortResponse:
    _ = admin
    return await SeaLinkAdminService(session).create_port(data)


@admin_router.patch(
    "/sea-ports/{port_id}",
    response_model=SeaPortResponse,
    summary="Update a sea port terminal coordinate, island group, or verification",
)
async def update_sea_port(
    port_id: int,
    data: SeaPortUpdate,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    admin: Annotated[User, Depends(require_admin)],
) -> SeaPortResponse:
    _ = admin
    return await SeaLinkAdminService(session).update_port(port_id, data)


@admin_router.get(
    "/sea-links",
    response_model=list[SeaLinkResponse],
    summary="List boat/ferry crossings connecting island groups",
)
async def list_sea_links(
    session: Annotated[AsyncSession, Depends(get_db_session)],
    admin: Annotated[User, Depends(require_admin)],
    include_inactive: bool = Query(default=True),
) -> list[SeaLinkResponse]:
    _ = admin
    return await SeaLinkAdminService(session).list_links(include_inactive=include_inactive)


@admin_router.post(
    "/sea-links",
    response_model=SeaLinkResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Create a boat/ferry sea link",
)
async def create_sea_link(
    data: SeaLinkCreate,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    admin: Annotated[User, Depends(require_admin)],
) -> SeaLinkResponse:
    _ = admin
    return await SeaLinkAdminService(session).create_link(data)


@admin_router.patch(
    "/sea-links/{link_id}",
    response_model=SeaLinkResponse,
    summary="Update boat link geometry polyline, crossing times, fares, or status",
)
async def update_sea_link(
    link_id: int,
    data: SeaLinkUpdate,
    session: Annotated[AsyncSession, Depends(get_db_session)],
    admin: Annotated[User, Depends(require_admin)],
) -> SeaLinkResponse:
    _ = admin
    return await SeaLinkAdminService(session).update_link(link_id, data)

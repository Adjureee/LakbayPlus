"""Business logic and validation for administrator sea-port & sea-link management."""

from __future__ import annotations

from datetime import datetime, timezone

from fastapi import status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.exceptions import LakbayAPIError
from app.features.sea_links.repository import SeaLinkRepository
from app.features.sea_links.schemas import (
    SeaLinkCreate,
    SeaLinkResponse,
    SeaLinkUpdate,
    SeaPortCreate,
    SeaPortResponse,
    SeaPortUpdate,
)


def _apply_verified_flag(values: dict) -> dict:
    if "verified" in values:
        verified = values.pop("verified")
        if verified is True:
            values["verified_at"] = datetime.now(timezone.utc)
        elif verified is False:
            values["verified_at"] = None
    return values


class SeaLinkAdminService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.repo = SeaLinkRepository(session)

    async def list_ports(self, *, include_inactive: bool = True) -> list[SeaPortResponse]:
        ports = await self.repo.list_all_ports(include_inactive=include_inactive)
        return [SeaPortResponse.model_validate(p) for p in ports]

    async def create_port(self, data: SeaPortCreate) -> SeaPortResponse:
        existing = await self.repo.get_port_by_name(data.name)
        if existing is not None:
            raise LakbayAPIError(
                "A sea port with that name already exists.",
                code="sea_port_duplicate_name",
                status_code=status.HTTP_409_CONFLICT,
            )
        values = _apply_verified_flag(data.model_dump())
        port = await self.repo.create_port(values)
        await self.session.commit()
        await self.session.refresh(port)
        return SeaPortResponse.model_validate(port)

    async def update_port(self, port_id: int, data: SeaPortUpdate) -> SeaPortResponse:
        port = await self.repo.get_port(port_id)
        if port is None:
            raise LakbayAPIError(
                "Sea port was not found.",
                code="sea_port_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
            )
        values = _apply_verified_flag(data.model_dump(exclude_unset=True))
        if not values:
            raise LakbayAPIError(
                "At least one field must be provided to update the sea port.",
                code="empty_sea_port_update",
                status_code=status.HTTP_400_BAD_REQUEST,
            )
        if "name" in values and values["name"] != port.name:
            existing = await self.repo.get_port_by_name(values["name"])
            if existing is not None and existing.port_id != port_id:
                raise LakbayAPIError(
                    "Another sea port with that name already exists.",
                    code="sea_port_duplicate_name",
                    status_code=status.HTTP_409_CONFLICT,
                )
        updated = await self.repo.update_port(port, values)
        await self.session.commit()
        await self.session.refresh(updated)
        return SeaPortResponse.model_validate(updated)

    async def list_links(self, *, include_inactive: bool = True) -> list[SeaLinkResponse]:
        links = await self.repo.list_all_links(include_inactive=include_inactive)
        return [SeaLinkResponse.from_orm_link(link) for link in links]

    async def create_link(self, data: SeaLinkCreate) -> SeaLinkResponse:
        await self._require_ports_exist(data.from_port_id, data.to_port_id)
        values = _apply_verified_flag(data.model_dump())
        link = await self.repo.create_link(values)
        await self.session.commit()
        loaded = await self.repo.get_link(link.link_id)
        return SeaLinkResponse.from_orm_link(loaded or link)

    async def update_link(self, link_id: int, data: SeaLinkUpdate) -> SeaLinkResponse:
        link = await self.repo.get_link(link_id)
        if link is None:
            raise LakbayAPIError(
                "Sea link was not found.",
                code="sea_link_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
            )
        values = _apply_verified_flag(data.model_dump(exclude_unset=True))
        if not values:
            raise LakbayAPIError(
                "At least one field must be provided to update the sea link.",
                code="empty_sea_link_update",
                status_code=status.HTTP_400_BAD_REQUEST,
            )
        next_from = values.get("from_port_id", link.from_port_id)
        next_to = values.get("to_port_id", link.to_port_id)
        if next_from == next_to:
            raise LakbayAPIError(
                "from_port_id and to_port_id must be different ports.",
                code="sea_link_same_port",
                status_code=status.HTTP_400_BAD_REQUEST,
            )
        if "from_port_id" in values or "to_port_id" in values:
            await self._require_ports_exist(next_from, next_to)
        await self.repo.update_link(link, values)
        await self.session.commit()
        self.session.expire_all()
        reloaded = await self.repo.get_link(link_id)
        return SeaLinkResponse.from_orm_link(reloaded or link)

    async def _require_ports_exist(self, from_port_id: int, to_port_id: int) -> None:
        from_port = await self.repo.get_port(from_port_id)
        if from_port is None:
            raise LakbayAPIError(
                "Departure sea port was not found.",
                code="sea_port_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
            )
        to_port = await self.repo.get_port(to_port_id)
        if to_port is None:
            raise LakbayAPIError(
                "Arrival sea port was not found.",
                code="sea_port_not_found",
                status_code=status.HTTP_404_NOT_FOUND,
            )

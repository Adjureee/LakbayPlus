from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.features.sea_links.models import SeaLink, SeaPort


class SeaLinkRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def list_active_links(self) -> list[SeaLink]:
        """Active links whose two piers are also active."""
        result = await self.session.execute(
            select(SeaLink).where(SeaLink.is_active.is_(True)).order_by(SeaLink.link_id)
        )
        return [
            link for link in result.unique().scalars().all()
            if link.from_port.is_active and link.to_port.is_active
        ]

    async def list_active_ports(self) -> list[SeaPort]:
        result = await self.session.execute(
            select(SeaPort).where(SeaPort.is_active.is_(True)).order_by(SeaPort.port_id)
        )
        return list(result.scalars().all())

    async def list_all_ports(self, *, include_inactive: bool = True) -> list[SeaPort]:
        stmt = select(SeaPort).order_by(SeaPort.port_id)
        if not include_inactive:
            stmt = stmt.where(SeaPort.is_active.is_(True))
        result = await self.session.execute(stmt)
        return list(result.scalars().all())

    async def get_port(self, port_id: int) -> SeaPort | None:
        result = await self.session.execute(
            select(SeaPort).where(SeaPort.port_id == port_id)
        )
        return result.scalar_one_or_none()

    async def get_port_by_name(self, name: str) -> SeaPort | None:
        result = await self.session.execute(
            select(SeaPort).where(SeaPort.name == name)
        )
        return result.scalar_one_or_none()

    async def create_port(self, values: dict) -> SeaPort:
        port = SeaPort(**values)
        self.session.add(port)
        await self.session.flush()
        return port

    async def update_port(self, port: SeaPort, values: dict) -> SeaPort:
        for key, value in values.items():
            setattr(port, key, value)
        await self.session.flush()
        return port

    async def list_all_links(self, *, include_inactive: bool = True) -> list[SeaLink]:
        stmt = select(SeaLink).order_by(SeaLink.link_id)
        if not include_inactive:
            stmt = stmt.where(SeaLink.is_active.is_(True))
        result = await self.session.execute(stmt)
        return list(result.unique().scalars().all())

    async def get_link(self, link_id: int) -> SeaLink | None:
        result = await self.session.execute(
            select(SeaLink).where(SeaLink.link_id == link_id)
        )
        return result.unique().scalar_one_or_none()

    async def create_link(self, values: dict) -> SeaLink:
        link = SeaLink(**values)
        self.session.add(link)
        await self.session.flush()
        return link

    async def update_link(self, link: SeaLink, values: dict) -> SeaLink:
        for key, value in values.items():
            setattr(link, key, value)
        await self.session.flush()
        return link

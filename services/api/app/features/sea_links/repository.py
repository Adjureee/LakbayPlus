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

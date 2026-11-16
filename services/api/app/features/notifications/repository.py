from datetime import UTC, datetime

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession
from sqlalchemy.orm import selectinload

from app.features.notifications.models import Notification, UserDeviceToken
from app.features.trips.models import Trip
from app.features.users.models import User


class NotificationRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def list_notifications(
        self,
        *,
        recipient_user_id: int,
        unread_only: bool,
        event_type: str | None,
        trip_id: int | None,
        limit: int,
        offset: int,
    ) -> list[Notification]:
        statement = (
            select(Notification)
            .where(
                Notification.recipient_user_id == recipient_user_id,
                Notification.status == "active",
            )
            .options(*_notification_options())
            .order_by(Notification.created_at.desc(), Notification.notification_id.desc())
            .offset(offset)
            .limit(limit)
        )

        if unread_only:
            statement = statement.where(Notification.read_at.is_(None))

        if event_type is not None:
            statement = statement.where(Notification.event_type == event_type)

        if trip_id is not None:
            statement = statement.where(Notification.trip_id == trip_id)

        result = await self.session.execute(statement)

        return list(result.scalars().all())

    async def get_notification_for_user(
        self,
        *,
        recipient_user_id: int,
        notification_id: int,
    ) -> Notification | None:
        result = await self.session.execute(
            select(Notification)
            .where(
                Notification.notification_id == notification_id,
                Notification.recipient_user_id == recipient_user_id,
                Notification.status == "active",
            )
            .options(*_notification_options())
        )

        return result.scalar_one_or_none()

    async def unread_count(self, *, recipient_user_id: int) -> int:
        result = await self.session.execute(
            select(func.count(Notification.notification_id)).where(
                Notification.recipient_user_id == recipient_user_id,
                Notification.status == "active",
                Notification.read_at.is_(None),
            )
        )

        return int(result.scalar_one())

    async def add_notifications(
        self,
        notifications: list[Notification],
    ) -> list[Notification]:
        if not notifications:
            return []

        self.session.add_all(notifications)
        await self.session.flush()

        return notifications

    async def mark_all_read(self, *, recipient_user_id: int) -> int:
        result = await self.session.execute(
            select(Notification).where(
                Notification.recipient_user_id == recipient_user_id,
                Notification.status == "active",
                Notification.read_at.is_(None),
            )
        )
        notifications = list(result.scalars().all())
        now = datetime.now(UTC)

        for notification in notifications:
            notification.read_at = now
            notification.updated_at = now

        await self.session.flush()

        return len(notifications)

    async def upsert_device_token(
        self,
        *,
        user_id: int,
        platform: str,
        device_token: str,
    ) -> UserDeviceToken:
        result = await self.session.execute(
            select(UserDeviceToken).where(
                UserDeviceToken.user_id == user_id,
                UserDeviceToken.device_token == device_token,
            )
        )
        existing = result.scalar_one_or_none()
        now = datetime.now(UTC)
        if existing is not None:
            existing.platform = platform
            existing.is_active = True
            existing.updated_at = now
            await self.session.flush()
            return existing

        token_row = UserDeviceToken(
            user_id=user_id,
            platform=platform,
            device_token=device_token,
            is_active=True,
        )
        self.session.add(token_row)
        await self.session.flush()
        return token_row

    async def deactivate_device_token(
        self,
        *,
        user_id: int,
        device_token: str,
    ) -> int:
        result = await self.session.execute(
            select(UserDeviceToken).where(
                UserDeviceToken.user_id == user_id,
                UserDeviceToken.device_token == device_token,
                UserDeviceToken.is_active.is_(True),
            )
        )
        rows = list(result.scalars().all())
        now = datetime.now(UTC)
        for row in rows:
            row.is_active = False
            row.updated_at = now
        await self.session.flush()
        return len(rows)

    async def list_active_device_tokens(
        self,
        *,
        user_ids: list[int],
    ) -> list[UserDeviceToken]:
        if not user_ids:
            return []
        result = await self.session.execute(
            select(UserDeviceToken).where(
                UserDeviceToken.user_id.in_(user_ids),
                UserDeviceToken.is_active.is_(True),
            )
        )
        return list(result.scalars().all())


def _notification_options():
    return (
        selectinload(Notification.actor),
        selectinload(Notification.trip),
    )

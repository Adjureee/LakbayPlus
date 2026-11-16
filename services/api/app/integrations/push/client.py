from collections.abc import Awaitable, Callable
import logging
from typing import Any

import httpx

from app.core.config import Settings, get_settings

logger = logging.getLogger(__name__)

FCMSender = Callable[[str, dict[str, Any]], Awaitable[bool]]
_test_fcm_sender: FCMSender | None = None


def set_fcm_sender_for_test(sender: FCMSender | None) -> None:
    global _test_fcm_sender
    _test_fcm_sender = sender


def reset_fcm_sender_for_test() -> None:
    global _test_fcm_sender
    _test_fcm_sender = None


class FCMClient:
    """Best-effort Firebase Cloud Messaging dispatcher (safe no-op unconfigured)."""

    def __init__(
        self,
        settings: Settings | None = None,
        *,
        sender: FCMSender | None = None,
    ) -> None:
        self.settings = settings or get_settings()
        self._sender = sender

    @property
    def is_configured(self) -> bool:
        return bool(
            self._sender
            or _test_fcm_sender
            or (self.settings.fcm_server_key and self.settings.fcm_server_key.strip())
        )

    async def send_push(
        self,
        *,
        device_token: str,
        title: str,
        body: str,
        data: dict[str, str],
    ) -> bool:
        payload: dict[str, Any] = {
            "to": device_token,
            "notification": {"title": title, "body": body},
            "data": data,
        }
        active_sender = self._sender or _test_fcm_sender
        if active_sender is not None:
            return await active_sender(device_token, payload)

        server_key = (self.settings.fcm_server_key or "").strip()
        if not server_key:
            logger.debug("FCM credentials not configured; skipping push dispatch.")
            return False

        async with httpx.AsyncClient(timeout=6.0) as client:
            response = await client.post(
                "https://fcm.googleapis.com/fcm/send",
                headers={
                    "Authorization": f"key={server_key}",
                    "Content-Type": "application/json",
                },
                json=payload,
            )
            return response.status_code == 200

    async def send_notifications(self, messages: list[dict[str, Any]]) -> int:
        if not messages or not self.is_configured:
            return 0
        sent = 0
        for item in messages:
            try:
                ok = await self.send_push(
                    device_token=str(item["device_token"]),
                    title=str(item["title"]),
                    body=str(item["body"]),
                    data=dict(item.get("data") or {}),
                )
                if ok:
                    sent += 1
            except Exception:
                logger.exception("FCM push dispatch failed for device token.")
        return sent


def get_fcm_client(settings: Settings | None = None) -> FCMClient:
    return FCMClient(settings=settings)

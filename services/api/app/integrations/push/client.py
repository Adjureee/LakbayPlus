"""Push notifications through Firebase Cloud Messaging (HTTP v1).

Google shut down the old ``/fcm/send`` endpoint that used a server key. The
current API needs an OAuth access token minted from a Firebase **service
account**, so this client signs a short-lived JWT with the account's private key
(RS256), exchanges it for an access token, caches that token until shortly
before it expires, and sends each message to
``https://fcm.googleapis.com/v1/projects/{project}/messages:send``.

Configuration (environment variables, never committed):

- ``FCM_SERVICE_ACCOUNT_JSON``: the service account key file's JSON text.
- ``FCM_PROJECT_ID``: optional; defaults to ``project_id`` inside that JSON.

Without them the client is "not configured" and sending is a quiet no-op, so
notifications still work in the app (it polls while open).

Sending is best effort: nothing here raises into the code that creates a
notification. Device tokens that Firebase says are no longer valid are reported
in ``invalid_tokens`` so the caller can switch them off.
"""

from __future__ import annotations

import base64
import json
import logging
import time
from collections.abc import Awaitable, Callable
from dataclasses import dataclass
from typing import Any

import httpx
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import padding

from app.core.config import Settings, get_settings

logger = logging.getLogger(__name__)

FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging"
DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token"
FCM_SEND_URL = "https://fcm.googleapis.com/v1/projects/{project_id}/messages:send"
ACCESS_TOKEN_LIFETIME_SECONDS = 3600
# Refresh a minute early so a token never expires mid-request.
EXPIRY_MARGIN_SECONDS = 60
REQUEST_TIMEOUT_SECONDS = 6.0
# Firebase error codes that mean "this device token will never work again".
_DEAD_TOKEN_CODES = {"UNREGISTERED", "INVALID_ARGUMENT", "NOT_FOUND"}

FCMSender = Callable[[str, dict[str, Any]], Awaitable[bool]]
_test_fcm_sender: FCMSender | None = None


def set_fcm_sender_for_test(sender: FCMSender | None) -> None:
    global _test_fcm_sender
    _test_fcm_sender = sender


def reset_fcm_sender_for_test() -> None:
    global _test_fcm_sender
    _test_fcm_sender = None


class FCMConfigError(ValueError):
    """The Firebase settings are present but unusable."""


@dataclass(frozen=True)
class _ServiceAccount:
    project_id: str
    client_email: str
    private_key: str
    token_uri: str


def _b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def _parse_service_account(settings: Settings) -> _ServiceAccount | None:
    raw = (settings.fcm_service_account_json or "").strip()
    if not raw:
        return None
    try:
        info = json.loads(raw)
    except ValueError as exc:
        raise FCMConfigError("FCM_SERVICE_ACCOUNT_JSON is not valid JSON.") from exc
    if not isinstance(info, dict):
        raise FCMConfigError("FCM_SERVICE_ACCOUNT_JSON must be a JSON object.")
    email = str(info.get("client_email") or "").strip()
    key = str(info.get("private_key") or "").strip()
    project = (settings.fcm_project_id or str(info.get("project_id") or "")).strip()
    if not email or not key or not project:
        raise FCMConfigError(
            "The service account needs client_email, private_key and a project id."
        )
    return _ServiceAccount(
        project_id=project,
        client_email=email,
        private_key=key,
        token_uri=str(info.get("token_uri") or DEFAULT_TOKEN_URI),
    )


def build_signed_assertion(account: _ServiceAccount, *, now: int | None = None) -> str:
    """The signed JWT (RS256) Google exchanges for an access token."""
    issued = int(now if now is not None else time.time())
    header = {"alg": "RS256", "typ": "JWT"}
    claims = {
        "iss": account.client_email,
        "scope": FCM_SCOPE,
        "aud": account.token_uri,
        "iat": issued,
        "exp": issued + ACCESS_TOKEN_LIFETIME_SECONDS,
    }
    signing_input = (
        _b64url(json.dumps(header, separators=(",", ":")).encode())
        + "."
        + _b64url(json.dumps(claims, separators=(",", ":")).encode())
    )
    key = serialization.load_pem_private_key(account.private_key.encode(), password=None)
    signature = key.sign(signing_input.encode("ascii"), padding.PKCS1v15(), hashes.SHA256())
    return signing_input + "." + _b64url(signature)


# One cached access token per service account, shared across requests.
_token_cache: dict[str, tuple[str, float]] = {}


def clear_token_cache() -> None:
    _token_cache.clear()


class FCMClient:
    """Best-effort FCM v1 dispatcher (a safe no-op when unconfigured)."""

    def __init__(
        self,
        settings: Settings | None = None,
        *,
        sender: FCMSender | None = None,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self.settings = settings or get_settings()
        self._sender = sender
        self._transport = transport
        self._account: _ServiceAccount | None = None
        self._account_error = False
        # Device tokens Firebase rejected as permanently invalid in the last send.
        self.invalid_tokens: set[str] = set()

    def _service_account(self) -> _ServiceAccount | None:
        if self._account is None and not self._account_error:
            try:
                self._account = _parse_service_account(self.settings)
            except FCMConfigError as exc:
                self._account_error = True
                logger.error("FCM is misconfigured: %s", exc)
        return self._account

    @property
    def is_configured(self) -> bool:
        return bool(self._sender or _test_fcm_sender or self._service_account())

    def _http(self) -> httpx.AsyncClient:
        return httpx.AsyncClient(timeout=REQUEST_TIMEOUT_SECONDS, transport=self._transport)

    async def _access_token(self, http: httpx.AsyncClient, account: _ServiceAccount) -> str | None:
        cache_key = f"{account.client_email}|{account.project_id}"
        cached = _token_cache.get(cache_key)
        if cached is not None and cached[1] - EXPIRY_MARGIN_SECONDS > time.time():
            return cached[0]
        assertion = build_signed_assertion(account)
        response = await http.post(
            account.token_uri,
            data={
                "grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                "assertion": assertion,
            },
        )
        if response.status_code != 200:
            logger.error("FCM access token request failed with HTTP %s.", response.status_code)
            return None
        body = response.json()
        token = str(body.get("access_token") or "")
        if not token:
            logger.error("FCM access token response had no access_token.")
            return None
        lifetime = int(body.get("expires_in") or ACCESS_TOKEN_LIFETIME_SECONDS)
        _token_cache[cache_key] = (token, time.time() + lifetime)
        return token

    @staticmethod
    def _message(device_token: str, title: str, body: str, data: dict[str, str]) -> dict[str, Any]:
        return {
            "message": {
                "token": device_token,
                "notification": {"title": title, "body": body},
                # FCM v1 only accepts string values in data.
                "data": {str(key): str(value) for key, value in data.items()},
                "android": {"priority": "HIGH"},
            }
        }

    @staticmethod
    def _is_dead_token(response: httpx.Response) -> bool:
        if response.status_code not in (400, 404):
            return False
        try:
            error = response.json().get("error", {})
        except ValueError:
            return False
        codes = {str(error.get("status") or "")}
        for detail in error.get("details") or []:
            if isinstance(detail, dict) and detail.get("errorCode"):
                codes.add(str(detail["errorCode"]))
        return bool(codes & _DEAD_TOKEN_CODES)

    async def send_push(
        self,
        *,
        device_token: str,
        title: str,
        body: str,
        data: dict[str, str],
    ) -> bool:
        active_sender = self._sender or _test_fcm_sender
        if active_sender is not None:
            payload = self._message(device_token, title, body, data)
            return await active_sender(device_token, payload["message"])

        account = self._service_account()
        if account is None:
            logger.debug("FCM credentials not configured; skipping push dispatch.")
            return False

        async with self._http() as http:
            return await self._send_with_retry(http, account, device_token, title, body, data)

    async def _send_with_retry(
        self,
        http: httpx.AsyncClient,
        account: _ServiceAccount,
        device_token: str,
        title: str,
        body: str,
        data: dict[str, str],
    ) -> bool:
        payload = self._message(device_token, title, body, data)
        url = FCM_SEND_URL.format(project_id=account.project_id)
        for attempt in (1, 2):
            access_token = await self._access_token(http, account)
            if access_token is None:
                return False
            response = await http.post(
                url, json=payload, headers={"Authorization": f"Bearer {access_token}"},
            )
            if response.status_code == 200:
                return True
            if response.status_code == 401 and attempt == 1:
                # The cached token was rejected (revoked or clock skew): mint a new one once.
                clear_token_cache()
                continue
            if self._is_dead_token(response):
                self.invalid_tokens.add(device_token)
                return False
            logger.warning(
                "FCM send failed with HTTP %s for device ...%s.",
                response.status_code, device_token[-6:],
            )
            return False
        return False

    async def send_notifications(self, messages: list[dict[str, Any]]) -> int:
        """Send each message; returns how many Firebase accepted."""
        self.invalid_tokens = set()
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
                logger.exception("FCM push dispatch failed for a device token.")
        return sent


def get_fcm_client(settings: Settings | None = None) -> FCMClient:
    return FCMClient(settings=settings)

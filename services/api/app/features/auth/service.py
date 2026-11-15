from datetime import UTC, datetime, timedelta
import secrets

import httpx
from fastapi import status
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import get_settings
from app.core.exceptions import LakbayAPIError
from app.core.security import (
    create_access_token,
    generate_refresh_token,
    hash_password,
    hash_refresh_token,
    verify_password,
)
from app.features.auth.repository import RefreshTokenRepository
from app.features.auth.schemas import (
    AdminRegisterRequest,
    AuthResponse,
    GoogleAuthRequest,
    LoginRequest,
    RefreshRequest,
    RegisterRequest,
    TokenResponse,
)
from app.features.users.models import User
from app.features.users.repository import UserRepository
from app.features.users.schemas import UserResponse


class AuthService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.users = UserRepository(session)
        self.refresh_tokens = RefreshTokenRepository(session)

    async def register_user(self, data: RegisterRequest) -> AuthResponse:
        user = await self._create_user(data=data, role="user")
        tokens = await self._issue_tokens(user)
        await self.session.commit()

        return _build_auth_response(user=user, tokens=tokens)

    async def register_admin(self, data: AdminRegisterRequest) -> AuthResponse:
        settings = get_settings()

        if (
            not settings.admin_registration_code
            or data.admin_registration_code != settings.admin_registration_code
        ):
            raise LakbayAPIError(
                "Admin registration code is invalid.",
                code="invalid_admin_registration_code",
                status_code=status.HTTP_403_FORBIDDEN,
            )

        user = await self._create_user(data=data, role="admin")
        tokens = await self._issue_tokens(user)
        await self.session.commit()

        return _build_auth_response(user=user, tokens=tokens)

    async def login(self, data: LoginRequest) -> AuthResponse:
        user = await self.users.get_by_email(_normalize_email(str(data.email)))

        if user is None or not verify_password(data.password, user.password_hash):
            raise LakbayAPIError(
                "Email or password is incorrect.",
                code="invalid_credentials",
                status_code=status.HTTP_401_UNAUTHORIZED,
            )

        if not user.is_active:
            raise LakbayAPIError(
                "User account is inactive.",
                code="user_inactive",
                status_code=status.HTTP_403_FORBIDDEN,
            )

        tokens = await self._issue_tokens(user)
        await self.session.commit()

        return _build_auth_response(user=user, tokens=tokens)

    async def google_login(
        self,
        data: GoogleAuthRequest,
        *,
        http_client: httpx.AsyncClient | None = None,
    ) -> AuthResponse:
        token_info = await _verify_google_id_token(
            data.id_token,
            http_client=http_client,
        )
        allowed_audiences = get_settings().google_client_id_list
        aud = str(token_info.get("aud") or "").strip()
        if allowed_audiences and aud not in allowed_audiences:
            raise LakbayAPIError(
                "Google token audience does not match this application.",
                code="invalid_google_token",
                status_code=status.HTTP_401_UNAUTHORIZED,
            )

        email_verified = token_info.get("email_verified")
        if email_verified not in (True, "true", "True"):
            raise LakbayAPIError(
                "Google account email must be verified.",
                code="unverified_google_email",
                status_code=status.HTTP_401_UNAUTHORIZED,
            )

        raw_email = str(token_info.get("email") or "").strip()
        if not raw_email:
            raise LakbayAPIError(
                "Google token did not include an email address.",
                code="invalid_google_token",
                status_code=status.HTTP_401_UNAUTHORIZED,
            )

        email = _normalize_email(raw_email)
        user = await self.users.get_by_email(email)
        if user is None:
            raw_name = str(token_info.get("name") or "").strip()
            fallback_name = email.split("@", 1)[0].replace(".", " ").title()
            full_name = (raw_name or fallback_name or "Lakbay Traveler")[:255]
            if len(full_name) < 2:
                full_name = "Lakbay Traveler"
            picture = str(token_info.get("picture") or "").strip() or None
            user = await self.users.create(
                full_name=full_name,
                email=email,
                password_hash=hash_password(secrets.token_urlsafe(32)),
                role="user",
                avatar_url=picture,
            )
        elif not user.is_active:
            raise LakbayAPIError(
                "User account is inactive.",
                code="user_inactive",
                status_code=status.HTTP_403_FORBIDDEN,
            )

        tokens = await self._issue_tokens(user)
        await self.session.commit()
        return _build_auth_response(user=user, tokens=tokens)

    async def refresh(self, data: RefreshRequest) -> AuthResponse:
        token_hash = hash_refresh_token(data.refresh_token)
        stored_token = await self.refresh_tokens.get_active_by_hash(token_hash)

        if stored_token is None:
            raise LakbayAPIError(
                "Refresh token is invalid or expired.",
                code="invalid_refresh_token",
                status_code=status.HTTP_401_UNAUTHORIZED,
            )

        user = await self.users.get_by_id(stored_token.user_id)

        if user is None or not user.is_active:
            raise LakbayAPIError(
                "Refresh token user is invalid.",
                code="invalid_refresh_token_user",
                status_code=status.HTTP_401_UNAUTHORIZED,
            )

        await self.refresh_tokens.revoke(stored_token)
        tokens = await self._issue_tokens(user)
        await self.session.commit()

        return _build_auth_response(user=user, tokens=tokens)

    async def logout(self, *, refresh_token: str, user: User) -> None:
        token_hash = hash_refresh_token(refresh_token)
        stored_token = await self.refresh_tokens.get_active_by_hash(token_hash)

        if stored_token is not None and stored_token.user_id == user.user_id:
            await self.refresh_tokens.revoke(stored_token)

        await self.session.commit()

    async def _create_user(self, *, data: RegisterRequest, role: str) -> User:
        email = _normalize_email(str(data.email))
        existing_user = await self.users.get_by_email(email)

        if existing_user is not None:
            raise LakbayAPIError(
                "Email is already registered.",
                code="email_already_registered",
                status_code=status.HTTP_409_CONFLICT,
            )

        return await self.users.create(
            full_name=data.full_name,
            email=email,
            password_hash=hash_password(data.password),
            role=role,
            avatar_url=data.avatar_url,
        )

    async def _issue_tokens(self, user: User) -> TokenResponse:
        settings = get_settings()
        access_token = create_access_token(user_id=user.user_id, role=user.role)
        refresh_token = generate_refresh_token()
        refresh_token_expires_at = datetime.now(UTC) + timedelta(
            days=settings.jwt_refresh_token_expire_days,
        )

        await self.refresh_tokens.create(
            user_id=user.user_id,
            token_hash=hash_refresh_token(refresh_token),
            expires_at=refresh_token_expires_at,
        )

        return TokenResponse(
            access_token=access_token,
            refresh_token=refresh_token,
            expires_in=settings.jwt_access_token_expire_minutes * 60,
        )


def _build_auth_response(*, user: User, tokens: TokenResponse) -> AuthResponse:
    return AuthResponse(
        user=UserResponse.model_validate(user),
        tokens=tokens,
    )


def _normalize_email(email: str) -> str:
    return email.strip().lower()


async def _verify_google_id_token(
    id_token: str,
    *,
    http_client: httpx.AsyncClient | None = None,
) -> dict[str, object]:
    url = "https://oauth2.googleapis.com/tokeninfo"
    try:
        if http_client is not None:
            response = await http_client.get(url, params={"id_token": id_token})
        else:
            async with httpx.AsyncClient(timeout=10.0) as client:
                response = await client.get(url, params={"id_token": id_token})
    except httpx.HTTPError as exc:
        raise LakbayAPIError(
            "Unable to verify Google token right now.",
            code="google_auth_unavailable",
            status_code=status.HTTP_502_BAD_GATEWAY,
        ) from exc

    if response.status_code != status.HTTP_200_OK:
        raise LakbayAPIError(
            "Google ID token is invalid or expired.",
            code="invalid_google_token",
            status_code=status.HTTP_401_UNAUTHORIZED,
        )

    payload = response.json()
    if not isinstance(payload, dict):
        raise LakbayAPIError(
            "Unexpected response from Google token verification.",
            code="invalid_google_token",
            status_code=status.HTTP_401_UNAUTHORIZED,
        )
    return payload


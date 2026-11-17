from datetime import datetime

from pydantic import BaseModel, ConfigDict, EmailStr, Field, field_validator

from app.features.users.usernames import USERNAME_RULE, is_valid_username, normalize_username


class UserResponse(BaseModel):
    user_id: int
    full_name: str
    username: str | None = None
    email: EmailStr
    role: str
    avatar_url: str | None
    cover_url: str | None = None
    is_active: bool
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


class UserUpdateRequest(BaseModel):
    full_name: str | None = Field(default=None, min_length=2, max_length=255)
    avatar_url: str | None = Field(default=None, max_length=2048)
    username: str | None = Field(default=None, max_length=40)

    @field_validator("username")
    @classmethod
    def validate_username(cls, value: str | None) -> str | None:
        if value is None:
            raise ValueError("username cannot be null.")
        cleaned = normalize_username(value)
        if not is_valid_username(cleaned):
            raise ValueError(USERNAME_RULE)
        return cleaned


class UserSearchItem(BaseModel):
    """What another traveler may see: never an email address."""

    user_id: int
    username: str
    full_name: str
    avatar_url: str | None = None


class AdminUserItem(BaseModel):
    user_id: int
    full_name: str
    email: EmailStr
    role: str
    is_active: bool
    has_active_session: bool


class AdminUserDirectoryResponse(BaseModel):
    total_users: int
    signed_in_users: int
    matching_users: int
    items: list[AdminUserItem]


class AdminUserStatusUpdate(BaseModel):
    is_active: bool


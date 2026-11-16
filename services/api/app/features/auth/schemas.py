from pydantic import BaseModel, EmailStr, Field, ConfigDict, field_validator, model_validator

from app.features.users.schemas import UserResponse


class RegisterRequest(BaseModel):
    full_name: str = Field(min_length=2, max_length=255)
    email: EmailStr
    password: str = Field(min_length=8, max_length=128)
    confirm_password: str = Field(min_length=8, max_length=128)
    avatar_url: str | None = Field(default=None, max_length=2048)

    @field_validator("full_name")
    @classmethod
    def validate_full_name(cls, value: str) -> str:
        cleaned = " ".join(value.split())
        if len(cleaned) < 2:
            raise ValueError("Please enter your full name (at least 2 characters).")
        if cleaned.lower() == "lakbay traveler":
            raise ValueError("Please enter your real full name.")
        return cleaned

    @model_validator(mode="after")
    def validate_password_confirmation(self) -> "RegisterRequest":
        if self.password != self.confirm_password:
            raise ValueError("Password and confirm_password must match.")

        return self


class AdminRegisterRequest(RegisterRequest):
    admin_registration_code: str = Field(min_length=1, max_length=255)


class LoginRequest(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=128)


class GoogleAuthRequest(BaseModel):
    id_token: str = Field(min_length=10, max_length=8192)
    # A Google email with no Lakbay account yet is only registered when the
    # traveler has confirmed it (the app asks first), never silently.
    confirm_new_account: bool = False


class RefreshRequest(BaseModel):
    refresh_token: str = Field(min_length=1)


class LogoutRequest(BaseModel):
    refresh_token: str = Field(min_length=1)


class TokenResponse(BaseModel):
    access_token: str
    refresh_token: str
    token_type: str = "bearer"
    expires_in: int


class AuthResponse(BaseModel):
    user: UserResponse
    tokens: TokenResponse


class MessageResponse(BaseModel):
    message: str

    model_config = ConfigDict(from_attributes=True)

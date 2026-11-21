from typing import Annotated, Literal

from pydantic import BaseModel, EmailStr, Field, StringConstraints

from app.schemas.common import RequestModel
from app.schemas.user import DisplayName, UserOut

# NIST SP 800-63B: at least 8 characters, allow long passphrases. The upper bound
# only guards against abuse; nothing is truncated.
Password = Annotated[str, Field(min_length=8, max_length=128)]
RefreshTokenStr = Annotated[str, StringConstraints(min_length=20, max_length=200)]


class RegisterRequest(RequestModel):
    email: EmailStr
    password: Password
    display_name: DisplayName


class LoginRequest(RequestModel):
    email: EmailStr
    password: Annotated[str, Field(min_length=1, max_length=128)]


class RefreshRequest(RequestModel):
    refresh_token: RefreshTokenStr


class LogoutRequest(RequestModel):
    refresh_token: RefreshTokenStr


class TokenPair(BaseModel):
    access_token: str
    refresh_token: str
    token_type: Literal["bearer"] = "bearer"  # noqa: S105 - OAuth2 token type, not a secret
    expires_in: int  # access token lifetime in seconds


class AuthResponse(BaseModel):
    user: UserOut
    tokens: TokenPair

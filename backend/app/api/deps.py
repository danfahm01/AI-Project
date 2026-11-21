"""Shared FastAPI dependencies: settings, DB session, current user, rate limits."""

from collections.abc import AsyncIterator
from typing import Annotated

from fastapi import Depends, Request
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.ext.asyncio import AsyncSession

from app.ai_providers.registry import ProviderRegistry
from app.core.config import Settings
from app.core.errors import AuthenticationError, RateLimitedError
from app.core.security import decode_access_token
from app.models.user import User

bearer_scheme = HTTPBearer(auto_error=False, description="Access token returned by /auth/login")


def get_app_settings(request: Request) -> Settings:
    return request.app.state.settings


SettingsDep = Annotated[Settings, Depends(get_app_settings)]


async def get_db(request: Request) -> AsyncIterator[AsyncSession]:
    async with request.app.state.db.sessionmaker() as session:
        yield session


DbSession = Annotated[AsyncSession, Depends(get_db)]


async def get_current_user(
    session: DbSession,
    settings: SettingsDep,
    credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer_scheme)],
) -> User:
    if credentials is None:
        raise AuthenticationError()
    user_id = decode_access_token(credentials.credentials, settings)
    user = await session.get(User, user_id)
    if user is None or not user.is_active:
        raise AuthenticationError("Account not found or disabled", code="invalid_token")
    return user


CurrentUser = Annotated[User, Depends(get_current_user)]


def get_provider_registry(request: Request) -> ProviderRegistry:
    return request.app.state.providers


ProvidersDep = Annotated[ProviderRegistry, Depends(get_provider_registry)]


async def enforce_rate_limit(request: Request, key: str, limit: int, window_seconds: int = 60) -> None:
    result = await request.app.state.rate_limiter.hit(key, limit, window_seconds)
    if not result.allowed:
        raise RateLimitedError(retry_after=result.reset_after)


async def limit_auth_requests(request: Request, settings: SettingsDep) -> None:
    """Per-IP limit for unauthenticated auth endpoints (brute-force protection)."""
    client_ip = request.client.host if request.client else "unknown"
    await enforce_rate_limit(request, f"auth:{client_ip}", settings.rate_limit_auth_per_minute)


async def limit_api_requests(request: Request, settings: SettingsDep, user: CurrentUser) -> None:
    """Per-user limit for authenticated endpoints."""
    await enforce_rate_limit(request, f"api:{user.id}", settings.rate_limit_api_per_minute)

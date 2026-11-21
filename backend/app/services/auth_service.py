import logging
import uuid
from datetime import timedelta

from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession
from starlette.concurrency import run_in_threadpool

from app.core.config import Settings
from app.core.errors import AuthenticationError, ConflictError, PermissionDeniedError
from app.core.security import (
    create_access_token,
    generate_refresh_token,
    hash_password,
    hash_token,
    password_needs_rehash,
    verify_dummy_password,
    verify_password,
)
from app.db.base import utcnow
from app.models.refresh_token import RefreshToken
from app.models.user import User
from app.repositories.preferences_repository import PreferencesRepository
from app.repositories.token_repository import RefreshTokenRepository
from app.repositories.user_repository import UserRepository
from app.schemas.auth import LoginRequest, RegisterRequest, TokenPair

logger = logging.getLogger(__name__)


def normalize_email(email: str) -> str:
    return email.strip().lower()


class AuthService:
    def __init__(self, session: AsyncSession, settings: Settings) -> None:
        self.session = session
        self.settings = settings
        self.users = UserRepository(session)
        self.tokens = RefreshTokenRepository(session)
        self.preferences = PreferencesRepository(session)

    async def register(self, data: RegisterRequest, *, user_agent: str | None) -> tuple[User, TokenPair]:
        email = normalize_email(data.email)
        if await self.users.get_by_email(email) is not None:
            raise ConflictError("An account with this email already exists", code="email_taken")

        password_hash = await run_in_threadpool(hash_password, data.password)
        try:
            user = await self.users.create(email=email, password_hash=password_hash, display_name=data.display_name)
            await self.preferences.get_or_create(user.id)
            tokens, _ = await self._issue_tokens(user, family_id=None, user_agent=user_agent)
            await self.session.commit()
        except IntegrityError as exc:  # concurrent registration with the same email
            await self.session.rollback()
            raise ConflictError("An account with this email already exists", code="email_taken") from exc
        logger.info("Registered user %s", user.id)
        return user, tokens

    async def login(self, data: LoginRequest, *, user_agent: str | None) -> tuple[User, TokenPair]:
        user = await self.users.get_by_email(normalize_email(data.email))
        if user is None:
            await run_in_threadpool(verify_dummy_password, data.password)
            raise AuthenticationError("Invalid email or password", code="invalid_credentials")
        if not await run_in_threadpool(verify_password, user.password_hash, data.password):
            raise AuthenticationError("Invalid email or password", code="invalid_credentials")
        if not user.is_active:
            raise PermissionDeniedError("This account is disabled", code="account_disabled")

        if password_needs_rehash(user.password_hash):
            user.password_hash = await run_in_threadpool(hash_password, data.password)
        user.last_login_at = utcnow()
        tokens, _ = await self._issue_tokens(user, family_id=None, user_agent=user_agent)
        await self.session.commit()
        return user, tokens

    async def refresh(self, raw_token: str, *, user_agent: str | None) -> TokenPair:
        record = await self.tokens.get_by_hash(hash_token(raw_token))
        if record is None:
            raise AuthenticationError("Invalid refresh token", code="invalid_refresh_token")

        now = utcnow()
        if record.revoked_at is not None:
            # A rotated token was presented again: treat the whole session as compromised.
            await self.tokens.revoke_family(record.family_id, now)
            await self.session.commit()
            logger.warning("Refresh token reuse detected for user %s; session revoked", record.user_id)
            raise AuthenticationError("Refresh token has been revoked", code="refresh_token_revoked")
        if record.expires_at <= now:
            raise AuthenticationError("Refresh token expired", code="refresh_token_expired")

        user = await self.users.get_by_id(record.user_id)
        if user is None or not user.is_active:
            await self.tokens.revoke_family(record.family_id, now)
            await self.session.commit()
            raise AuthenticationError("Invalid refresh token", code="invalid_refresh_token")

        tokens, new_record = await self._issue_tokens(user, family_id=record.family_id, user_agent=user_agent)
        record.revoked_at = now
        record.replaced_by_id = new_record.id
        await self.session.commit()
        return tokens

    async def logout(self, raw_token: str) -> None:
        record = await self.tokens.get_by_hash(hash_token(raw_token))
        if record is not None:
            await self.tokens.revoke_family(record.family_id, utcnow())
            await self.session.commit()

    async def _issue_tokens(
        self, user: User, *, family_id: uuid.UUID | None, user_agent: str | None
    ) -> tuple[TokenPair, RefreshToken]:
        access_token, expires_in = create_access_token(user.id, self.settings)
        raw_refresh = generate_refresh_token()
        record = await self.tokens.create(
            user_id=user.id,
            token_hash=hash_token(raw_refresh),
            family_id=family_id or uuid.uuid4(),
            expires_at=utcnow() + timedelta(days=self.settings.refresh_token_ttl_days),
            user_agent=user_agent,
        )
        return TokenPair(access_token=access_token, refresh_token=raw_refresh, expires_in=expires_in), record

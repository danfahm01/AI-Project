from collections.abc import AsyncIterator, Awaitable, Callable
from pathlib import Path
from typing import Any

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient

from app.core.config import Settings
from app.db.base import Base
from app.main import create_app

TEST_PASSWORD = "correct horse battery staple"


def make_settings(tmp_path: Path, **overrides: Any) -> Settings:
    values: dict[str, Any] = {
        "app_env": "test",
        "database_url": f"sqlite+aiosqlite:///{(tmp_path / 'test.db').as_posix()}",
        "jwt_secret": "test-secret-" + "x" * 52,
        "redis_url": None,
        "rate_limit_auth_per_minute": 1000,
        "rate_limit_api_per_minute": 1000,
        "openai_api_key": None,
        "gemini_api_key": None,
        "attachment_storage_dir": str(tmp_path / "attachments"),
        "log_level": "WARNING",
    }
    values.update(overrides)
    return Settings(_env_file=None, **values)


@pytest.fixture
def settings(tmp_path: Path) -> Settings:
    return make_settings(tmp_path)


@pytest.fixture
async def app(settings: Settings) -> AsyncIterator[FastAPI]:
    application = create_app(settings)
    async with application.router.lifespan_context(application):
        async with application.state.db.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        yield application


@pytest.fixture
async def client(app: FastAPI) -> AsyncIterator[AsyncClient]:
    async with AsyncClient(transport=ASGITransport(app=app), base_url="http://testserver") as http:
        yield http


RegisterFn = Callable[..., Awaitable[dict[str, Any]]]


@pytest.fixture
def register(client: AsyncClient) -> RegisterFn:
    async def _register(email: str = "ana@example.com", password: str = TEST_PASSWORD, name: str = "Ana") -> dict:
        response = await client.post(
            "/api/v1/auth/register", json={"email": email, "password": password, "display_name": name}
        )
        assert response.status_code == 201, response.text
        return response.json()

    return _register


@pytest.fixture
async def auth_headers(register: RegisterFn) -> dict[str, str]:
    data = await register()
    return {"Authorization": f"Bearer {data['tokens']['access_token']}"}

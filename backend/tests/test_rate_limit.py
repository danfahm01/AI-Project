import os
import time
import uuid
from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from httpx import ASGITransport, AsyncClient
from redis.asyncio import Redis

from app.core.rate_limit import InMemoryRateLimitBackend, RedisRateLimitBackend, build_rate_limit_backend
from app.db.base import Base
from app.main import create_app
from tests.conftest import make_settings

# Integration tests against a real Redis run when this is set (CI starts one).
REDIS_TEST_URL = os.environ.get("REDIS_TEST_URL")


class FakeClock:
    def __init__(self, now: float = 1_000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


async def test_in_memory_backend_fixed_window() -> None:
    clock = FakeClock(1_000.0)
    backend = InMemoryRateLimitBackend(clock=clock)

    results = [await backend.hit("k", limit=3, window_seconds=60) for _ in range(4)]
    assert [r.allowed for r in results] == [True, True, True, False]
    assert results[0].remaining == 2
    assert results[3].remaining == 0
    assert 1 <= results[3].reset_after <= 60

    clock.now += 60  # next window
    assert (await backend.hit("k", limit=3, window_seconds=60)).allowed
    # Keys are independent.
    assert (await backend.hit("other", limit=3, window_seconds=60)).remaining == 2


@pytest.mark.skipif(not REDIS_TEST_URL, reason="set REDIS_TEST_URL to run against a real Redis")
async def test_redis_backend_counts_across_clients() -> None:
    assert REDIS_TEST_URL is not None
    # Two backends = two API workers sharing one Redis.
    first = RedisRateLimitBackend(Redis.from_url(REDIS_TEST_URL), prefix=f"test-{uuid.uuid4().hex}")
    second = RedisRateLimitBackend(Redis.from_url(REDIS_TEST_URL), prefix=first._prefix)
    try:
        assert await first.ping()
        results = [await backend.hit("k", limit=3, window_seconds=60) for backend in (first, second, first, second)]
        assert [r.allowed for r in results] == [True, True, True, False]
        assert [r.remaining for r in results] == [2, 1, 0, 0]
        assert 1 <= results[-1].reset_after <= 60
        assert (await first.hit("other", limit=3, window_seconds=60)).remaining == 2
    finally:
        await first.aclose()
        await second.aclose()


async def test_redis_outage_fails_open_quickly(tmp_path: Path) -> None:
    # Nothing listens on port 1: every call fails. Rate limiting must not take the
    # API down, nor stall requests in client retries.
    backend = build_rate_limit_backend(make_settings(tmp_path, redis_url="redis://127.0.0.1:1/0"))
    assert isinstance(backend, RedisRateLimitBackend)
    try:
        started = time.perf_counter()
        result = await backend.hit("k", limit=1, window_seconds=60)
        assert result.allowed
        assert not await backend.ping()
        # Two calls, each at most a connect attempt plus one retry (0.5 s timeouts;
        # Windows needs up to ~2 s to refuse a loopback connection).
        assert time.perf_counter() - started < 10
    finally:
        await backend.aclose()


def test_in_memory_backend_without_redis(tmp_path: Path) -> None:
    assert isinstance(build_rate_limit_backend(make_settings(tmp_path)), InMemoryRateLimitBackend)


@pytest.fixture
async def strict_client(tmp_path: Path) -> AsyncIterator[AsyncClient]:
    app = create_app(make_settings(tmp_path, rate_limit_auth_per_minute=3))
    async with app.router.lifespan_context(app):
        async with app.state.db.engine.begin() as connection:
            await connection.run_sync(Base.metadata.create_all)
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://testserver") as http:
            yield http


async def test_auth_endpoints_are_rate_limited(strict_client: AsyncClient) -> None:
    body = {"email": "nobody@example.com", "password": "wrong-password"}
    statuses = [(await strict_client.post("/api/v1/auth/login", json=body)).status_code for _ in range(4)]
    assert statuses == [401, 401, 401, 429]

    limited = await strict_client.post("/api/v1/auth/login", json=body)
    assert limited.json()["error"]["code"] == "rate_limited"
    assert int(limited.headers["retry-after"]) >= 1

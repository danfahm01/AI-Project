"""Fixed-window rate limiting with Redis (shared across workers) or in-process storage."""

import logging
import math
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Protocol

from redis.asyncio import Redis
from redis.asyncio.retry import Retry
from redis.backoff import NoBackoff
from redis.exceptions import RedisError

from app.core.config import Settings

logger = logging.getLogger(__name__)


@dataclass(frozen=True, slots=True)
class RateLimitResult:
    allowed: bool
    limit: int
    remaining: int
    reset_after: int  # seconds until the current window resets


class RateLimitBackend(Protocol):
    async def hit(self, key: str, limit: int, window_seconds: int) -> RateLimitResult: ...

    async def ping(self) -> bool: ...

    async def aclose(self) -> None: ...


def _result(count: int, limit: int, now: float, window_seconds: int) -> RateLimitResult:
    window_end = (math.floor(now / window_seconds) + 1) * window_seconds
    return RateLimitResult(
        allowed=count <= limit,
        limit=limit,
        remaining=max(0, limit - count),
        reset_after=max(1, math.ceil(window_end - now)),
    )


class InMemoryRateLimitBackend:
    """Single-process limiter for local development and tests.

    Runs on one event loop, and ``hit`` never awaits, so no lock is needed.
    """

    _PRUNE_EVERY = 1024

    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._windows: dict[str, tuple[int, int, int]] = {}  # key -> (window_index, window_seconds, count)
        self._hits = 0

    async def hit(self, key: str, limit: int, window_seconds: int) -> RateLimitResult:
        now = self._clock()
        window = math.floor(now / window_seconds)
        stored = self._windows.get(key)
        count = stored[2] + 1 if stored and stored[0] == window else 1
        self._windows[key] = (window, window_seconds, count)

        self._hits += 1
        if self._hits % self._PRUNE_EVERY == 0:
            self._prune(now)
        return _result(count, limit, now, window_seconds)

    def _prune(self, now: float) -> None:
        expired = [k for k, (w, ws, _) in self._windows.items() if w != math.floor(now / ws)]
        for key in expired:
            del self._windows[key]

    async def ping(self) -> bool:
        return True

    async def aclose(self) -> None:
        self._windows.clear()


class RedisRateLimitBackend:
    def __init__(self, client: Redis, prefix: str = "rl") -> None:
        self._client = client
        self._prefix = prefix

    async def hit(self, key: str, limit: int, window_seconds: int) -> RateLimitResult:
        now = time.time()
        window = math.floor(now / window_seconds)
        redis_key = f"{self._prefix}:{key}:{window}"
        try:
            async with self._client.pipeline(transaction=True) as pipe:
                pipe.incr(redis_key)
                pipe.expire(redis_key, window_seconds + 1)
                count, _ = await pipe.execute()
        except RedisError:
            # Fail open: rate limiting is defence in depth and must not take the API down.
            logger.exception("Rate limiter unavailable; allowing request")
            return RateLimitResult(allowed=True, limit=limit, remaining=limit, reset_after=window_seconds)
        return _result(int(count), limit, now, window_seconds)

    async def ping(self) -> bool:
        try:
            return bool(await self._client.ping())
        except RedisError:
            return False

    async def aclose(self) -> None:
        await self._client.aclose()


def build_rate_limit_backend(settings: Settings) -> RateLimitBackend:
    if settings.redis_url:
        # redis-py retries 10 times with backoff and 5 s timeouts by default: an outage
        # would stall every request for many seconds before failing open. Redis is on
        # the local network, so fail fast instead (one quick retry, short timeouts).
        client = Redis.from_url(
            settings.redis_url,
            socket_connect_timeout=0.5,
            socket_timeout=0.5,
            retry=Retry(NoBackoff(), retries=1),
        )
        return RedisRateLimitBackend(client)
    if settings.app_env == "production":
        logger.warning("REDIS_URL is not set; rate limits are per-process only")
    return InMemoryRateLimitBackend()

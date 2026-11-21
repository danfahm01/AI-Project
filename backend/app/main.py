"""FastAPI application factory.

Run locally:  uvicorn app.main:create_app --factory --reload
"""

import asyncio
import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app import __version__
from app.ai_providers.registry import build_provider_registry
from app.api import health
from app.api.v1 import api_router
from app.core.config import Settings, get_settings
from app.core.errors import register_exception_handlers
from app.core.logging import setup_logging
from app.core.middleware import RequestContextMiddleware
from app.core.rate_limit import build_rate_limit_backend
from app.db.session import Database
from app.services.attachment_storage import AttachmentStorage

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings: Settings = app.state.settings
    app.state.db = Database(
        settings.database_url,
        echo=settings.database_echo,
        pool_size=settings.database_pool_size,
        max_overflow=settings.database_max_overflow,
    )
    app.state.rate_limiter = build_rate_limit_backend(settings)
    app.state.providers = build_provider_registry(settings)
    app.state.attachment_storage = AttachmentStorage(settings.attachment_storage_dir)
    app.state.background_tasks = set()  # in-flight chat generations
    logger.info(
        "Started %s v%s (env=%s, db=%s, rate limiter=%s, providers=%d)",
        settings.app_name,
        __version__,
        settings.app_env,
        "sqlite" if settings.is_sqlite else "postgresql",
        "redis" if settings.redis_url else "in-memory",
        len(app.state.providers.list()),
    )
    try:
        yield
    finally:
        # Stop in-flight generations; each saves its partial reply as "cancelled".
        tasks = list(app.state.background_tasks)
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        await app.state.providers.aclose()
        await app.state.rate_limiter.aclose()
        await app.state.db.dispose()


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or get_settings()
    setup_logging(settings.log_level)

    docs_enabled = settings.enable_api_docs
    app = FastAPI(
        title=settings.app_name,
        version=__version__,
        lifespan=lifespan,
        docs_url="/docs" if docs_enabled else None,
        redoc_url="/redoc" if docs_enabled else None,
        openapi_url="/openapi.json" if docs_enabled else None,
    )
    app.state.settings = settings

    # The last-added middleware is outermost: CORS wraps RequestContext, so even the
    # last-resort 500 produced by RequestContext carries CORS headers to browsers.
    app.add_middleware(RequestContextMiddleware)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_origin_regex=settings.cors_origin_regex,
        allow_credentials=False,  # bearer tokens, no cookies
        allow_methods=["GET", "POST", "PATCH", "PUT", "DELETE", "OPTIONS"],
        allow_headers=["Authorization", "Content-Type", "X-Request-ID"],
        expose_headers=["X-Request-ID", "Retry-After"],
        max_age=600,
    )

    register_exception_handlers(app)
    app.include_router(health.router)
    app.include_router(api_router, prefix=settings.api_v1_prefix)
    return app

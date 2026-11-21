import asyncio
from logging.config import fileConfig

from alembic import context
from sqlalchemy import pool
from sqlalchemy.engine import Connection, make_url
from sqlalchemy.ext.asyncio import create_async_engine

import app.models  # noqa: F401  (registers every table on Base.metadata)
from app.core.config import get_settings
from app.db.base import Base
from app.db.session import ensure_sqlite_directory

config = context.config
if config.config_file_name is not None and config.attributes.get("configure_logger", True):
    fileConfig(config.config_file_name)

target_metadata = Base.metadata


def _database_url() -> str:
    return config.get_main_option("sqlalchemy.url") or get_settings().database_url


def _configure_kwargs(url: str) -> dict:
    return {
        "target_metadata": target_metadata,
        "render_as_batch": url.startswith("sqlite"),  # SQLite needs batch mode for ALTER TABLE
        "compare_type": True,
        "user_module_prefix": "app_types.",
    }


def run_migrations_offline() -> None:
    url = _database_url()
    context.configure(url=url, literal_binds=True, dialect_opts={"paramstyle": "named"}, **_configure_kwargs(url))
    with context.begin_transaction():
        context.run_migrations()


def _run_sync_migrations(connection: Connection) -> None:
    context.configure(connection=connection, **_configure_kwargs(str(connection.engine.url)))
    with context.begin_transaction():
        context.run_migrations()


async def run_migrations_online() -> None:
    url = make_url(_database_url())
    if url.get_backend_name() == "sqlite":
        ensure_sqlite_directory(url)  # a fresh checkout has no data/ directory yet
    engine = create_async_engine(url, poolclass=pool.NullPool)
    async with engine.connect() as connection:
        await connection.run_sync(_run_sync_migrations)
    await engine.dispose()


if context.is_offline_mode():
    run_migrations_offline()
else:
    asyncio.run(run_migrations_online())

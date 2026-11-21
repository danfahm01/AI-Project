from pathlib import Path
from typing import Any

from sqlalchemy import event, text
from sqlalchemy.engine import URL, make_url
from sqlalchemy.ext.asyncio import AsyncEngine, AsyncSession, async_sessionmaker, create_async_engine


def _enable_sqlite_foreign_keys(dbapi_connection: Any, _record: Any) -> None:
    cursor = dbapi_connection.cursor()
    cursor.execute("PRAGMA foreign_keys=ON")
    cursor.close()


def ensure_sqlite_directory(url: URL) -> None:
    database = url.database
    if database and database != ":memory:" and not database.startswith("file:"):
        Path(database).expanduser().resolve().parent.mkdir(parents=True, exist_ok=True)


class Database:
    """Owns the async engine and session factory for the application's lifetime."""

    def __init__(self, database_url: str, *, echo: bool = False, pool_size: int = 10, max_overflow: int = 10) -> None:
        url = make_url(database_url)
        options: dict[str, Any] = {"echo": echo}
        self.is_sqlite = url.get_backend_name() == "sqlite"
        if self.is_sqlite:
            ensure_sqlite_directory(url)
        else:
            # pool_recycle replaces connections before idle timeouts on proxies/managed
            # databases drop them; pre_ping catches the rest (e.g. after a DB restart).
            options.update(pool_pre_ping=True, pool_size=pool_size, max_overflow=max_overflow, pool_recycle=1800)

        self.engine: AsyncEngine = create_async_engine(url, **options)
        if self.is_sqlite:
            event.listen(self.engine.sync_engine, "connect", _enable_sqlite_foreign_keys)

        self.sessionmaker: async_sessionmaker[AsyncSession] = async_sessionmaker(
            self.engine, expire_on_commit=False, autoflush=False
        )

    async def ping(self) -> bool:
        try:
            async with self.engine.connect() as connection:
                await connection.execute(text("SELECT 1"))
        except Exception:
            return False
        return True

    async def dispose(self) -> None:
        await self.engine.dispose()

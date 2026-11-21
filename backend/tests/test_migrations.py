"""Migrations must produce exactly the schema the models describe, and be reversible."""

from pathlib import Path

from alembic import command
from alembic.autogenerate import compare_metadata
from alembic.config import Config
from alembic.migration import MigrationContext
from sqlalchemy import create_engine, inspect

import app.models  # noqa: F401
from app.db.base import Base

BACKEND_DIR = Path(__file__).resolve().parents[1]
EXPECTED_TABLES = {
    "users",
    "refresh_tokens",
    "conversations",
    "messages",
    "user_preferences",
    "ai_provider_settings",
    "conversation_attachments",
    "voice_sessions",
}


def _alembic_config(db_path: Path) -> Config:
    config = Config(str(BACKEND_DIR / "alembic.ini"))
    config.set_main_option("script_location", str(BACKEND_DIR / "alembic"))
    config.set_main_option("sqlalchemy.url", f"sqlite+aiosqlite:///{db_path.as_posix()}")
    config.attributes["configure_logger"] = False
    return config


def test_upgrade_matches_models_and_downgrade_is_clean(tmp_path: Path) -> None:
    db_path = tmp_path / "migrations.db"
    config = _alembic_config(db_path)
    sync_engine = create_engine(f"sqlite:///{db_path.as_posix()}")

    command.upgrade(config, "head")
    with sync_engine.connect() as connection:
        assert set(inspect(connection).get_table_names()) >= EXPECTED_TABLES
        diff = compare_metadata(MigrationContext.configure(connection), Base.metadata)
        assert diff == [], f"Models and migrations disagree: {diff}"

    command.downgrade(config, "base")
    with sync_engine.connect() as connection:
        assert set(inspect(connection).get_table_names()) <= {"alembic_version"}
    sync_engine.dispose()

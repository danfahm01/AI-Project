"""Regression: `alembic upgrade head` must work on a fresh checkout where the
SQLite data directory does not exist yet."""

from pathlib import Path

from alembic import command

from tests.test_migrations import _alembic_config


def test_upgrade_creates_missing_sqlite_directory(tmp_path: Path) -> None:
    db_path = tmp_path / "does" / "not" / "exist" / "dev.db"
    command.upgrade(_alembic_config(db_path), "head")
    assert db_path.exists()

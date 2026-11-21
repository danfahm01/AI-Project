from typing import Any

from sqlalchemy import JSON, Boolean, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, TimestampMixin, UUIDPrimaryKeyMixin


class AIProviderSetting(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    """Server-wide provider configuration managed by operators.

    API keys are NOT stored here; they come from environment variables only.
    """

    __tablename__ = "ai_provider_settings"

    provider: Mapped[str] = mapped_column(String(50), unique=True)
    is_enabled: Mapped[bool] = mapped_column(Boolean, default=True, server_default="1")
    default_model: Mapped[str | None] = mapped_column(String(100))
    allowed_models: Mapped[list[str] | None] = mapped_column(JSON)
    config: Mapped[dict[str, Any] | None] = mapped_column(JSON)

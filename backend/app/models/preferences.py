import enum
import uuid
from typing import Any

from sqlalchemy import JSON, Boolean, Enum, Float, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, TimestampMixin


class ThemeMode(enum.StrEnum):
    SYSTEM = "system"
    LIGHT = "light"
    DARK = "dark"


class VoiceMode(enum.StrEnum):
    HANDS_FREE = "hands_free"  # automatic speech detection (VAD) decides turns
    PUSH_TO_TALK = "push_to_talk"


def _enum_values(enum_cls: type[enum.Enum]) -> list[str]:
    return [member.value for member in enum_cls]


class UserPreferences(TimestampMixin, Base):
    """Account-wide preferences. Device-specific choices (e.g. which microphone)
    are stored on the device, not here."""

    __tablename__ = "user_preferences"

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    theme: Mapped[ThemeMode] = mapped_column(
        Enum(ThemeMode, native_enum=False, length=20, values_callable=_enum_values, validate_strings=True),
        default=ThemeMode.SYSTEM,
    )
    language: Mapped[str | None] = mapped_column(String(35))  # BCP 47 tag, e.g. "id-ID"
    default_provider: Mapped[str | None] = mapped_column(String(50))
    default_model: Mapped[str | None] = mapped_column(String(100))
    # Realtime model for voice mode (text and voice models are chosen separately).
    voice_provider: Mapped[str | None] = mapped_column(String(50))
    voice_model: Mapped[str | None] = mapped_column(String(100))
    voice_name: Mapped[str | None] = mapped_column(String(100))
    speaking_rate: Mapped[float | None] = mapped_column(Float)
    auto_speech_detection: Mapped[bool] = mapped_column(Boolean, default=True, server_default="1")
    voice_mode: Mapped[VoiceMode] = mapped_column(
        Enum(VoiceMode, native_enum=False, length=20, values_callable=_enum_values, validate_strings=True),
        default=VoiceMode.HANDS_FREE,
    )
    audio_settings: Mapped[dict[str, Any] | None] = mapped_column(JSON)

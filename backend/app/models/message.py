import enum
import uuid
from datetime import datetime
from typing import Any

from sqlalchemy import JSON, Enum, ForeignKey, Integer, String, Text, UniqueConstraint
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, TimestampMixin, UUIDPrimaryKeyMixin
from app.db.types import UTCDateTime


class MessageRole(enum.StrEnum):
    USER = "user"
    ASSISTANT = "assistant"
    SYSTEM = "system"
    TOOL = "tool"


class MessageStatus(enum.StrEnum):
    COMPLETE = "complete"
    STREAMING = "streaming"
    ERROR = "error"
    CANCELLED = "cancelled"


def _enum_values(enum_cls: type[enum.Enum]) -> list[str]:
    return [member.value for member in enum_cls]


class Message(UUIDPrimaryKeyMixin, TimestampMixin, Base):
    __tablename__ = "messages"
    # (conversation_id, seq) is unique and doubles as the ordering index.
    __table_args__ = (UniqueConstraint("conversation_id", "seq", name="uq_messages_conversation_id_seq"),)

    conversation_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("conversations.id", ondelete="CASCADE"))
    # Position within the conversation (1, 2, 3, ...). Timestamps alone can collide.
    seq: Mapped[int] = mapped_column(Integer)
    role: Mapped[MessageRole] = mapped_column(
        Enum(MessageRole, native_enum=False, length=20, values_callable=_enum_values, validate_strings=True)
    )
    content: Mapped[str] = mapped_column(Text, default="")
    status: Mapped[MessageStatus] = mapped_column(
        Enum(MessageStatus, native_enum=False, length=20, values_callable=_enum_values, validate_strings=True),
        default=MessageStatus.COMPLETE,
    )

    # Model metadata (assistant messages).
    provider: Mapped[str | None] = mapped_column(String(50))
    model: Mapped[str | None] = mapped_column(String(100))

    # Token usage, when the provider reports it.
    input_tokens: Mapped[int | None] = mapped_column(Integer)
    output_tokens: Mapped[int | None] = mapped_column(Integer)
    total_tokens: Mapped[int | None] = mapped_column(Integer)

    # Voice turns: duration, sample rate, format, transcript source, ...
    audio_metadata: Mapped[dict[str, Any] | None] = mapped_column(JSON)
    # Provider-specific extras (finish reason, response ids, ...).
    extra: Mapped[dict[str, Any] | None] = mapped_column(JSON)

    edited_at: Mapped[datetime | None] = mapped_column(UTCDateTime())

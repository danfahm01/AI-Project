import uuid
from datetime import datetime

from sqlalchemy import ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, CreatedAtMixin, UUIDPrimaryKeyMixin
from app.db.types import UTCDateTime


class VoiceSession(UUIDPrimaryKeyMixin, CreatedAtMixin, Base):
    """A realtime voice session minted by the backend.

    Audio flows directly between the client and the provider (WebRTC); this row
    is what authorises the client to store that session's transcripts.
    """

    __tablename__ = "voice_sessions"

    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    conversation_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("conversations.id", ondelete="CASCADE"), index=True)
    provider: Mapped[str] = mapped_column(String(50))
    model: Mapped[str] = mapped_column(String(100))
    voice: Mapped[str | None] = mapped_column(String(100))
    # Expiry of the short-lived client secret handed to the client.
    token_expires_at: Mapped[datetime] = mapped_column(UTCDateTime())
    ended_at: Mapped[datetime | None] = mapped_column(UTCDateTime())

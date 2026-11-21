import uuid

from sqlalchemy import BigInteger, ForeignKey, String
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base, CreatedAtMixin, UUIDPrimaryKeyMixin

IMAGE_TYPES = frozenset({"image/png", "image/jpeg", "image/webp"})
PDF_TYPE = "application/pdf"


class ConversationAttachment(UUIDPrimaryKeyMixin, CreatedAtMixin, Base):
    """Uploaded file metadata. File bytes live in file storage under ``storage_key``.

    An upload is *pending* (no conversation, no message) until it is sent with a
    message; then both are set.
    """

    __tablename__ = "conversation_attachments"

    conversation_id: Mapped[uuid.UUID | None] = mapped_column(
        ForeignKey("conversations.id", ondelete="CASCADE"), index=True
    )
    message_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("messages.id", ondelete="SET NULL"), index=True)
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), index=True)
    filename: Mapped[str] = mapped_column(String(255))
    content_type: Mapped[str] = mapped_column(String(127))
    size_bytes: Mapped[int] = mapped_column(BigInteger)
    sha256: Mapped[str] = mapped_column(String(64))
    storage_key: Mapped[str] = mapped_column(String(512), unique=True)

    @property
    def kind(self) -> str:
        return "pdf" if self.content_type == PDF_TYPE else "image"

import uuid
from datetime import datetime
from typing import Literal

from pydantic import BaseModel

from app.models.attachment import ConversationAttachment
from app.schemas.common import APIModel


class AttachmentOut(APIModel):
    id: uuid.UUID
    kind: Literal["image", "pdf"]
    filename: str
    content_type: str
    size_bytes: int
    conversation_id: uuid.UUID | None
    message_id: uuid.UUID | None
    created_at: datetime

    @classmethod
    def from_model(cls, attachment: ConversationAttachment) -> "AttachmentOut":
        return cls.model_validate(attachment)


class AttachmentLink(BaseModel):
    """A short-lived download link (no Authorization header needed), for opening a
    file in a browser or a viewer app. ``path`` is relative to the API base URL."""

    path: str
    expires_at: datetime

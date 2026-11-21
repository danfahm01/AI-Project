import uuid
from collections.abc import Iterable
from datetime import datetime
from typing import Annotated, Any

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, StringConstraints

from app.models.attachment import ConversationAttachment
from app.models.message import Message, MessageRole, MessageStatus
from app.schemas.attachment import AttachmentOut
from app.schemas.common import APIModel, RequestModel

MAX_MESSAGE_CHARS = 32_000


def _not_blank(value: str) -> str:
    if not value.strip():
        raise ValueError("Message content must not be blank")
    return value


# Whitespace is preserved (code blocks, indentation); blank messages are rejected.
MessageContent = Annotated[
    str, StringConstraints(min_length=1, max_length=MAX_MESSAGE_CHARS), AfterValidator(_not_blank)
]


class MessageCreate(RequestModel):
    """Clients can only author user messages; assistant messages come from the AI pipeline."""

    model_config = ConfigDict(str_strip_whitespace=False)

    content: MessageContent


class MessageUpdate(RequestModel):
    model_config = ConfigDict(str_strip_whitespace=False)

    content: MessageContent


class TokenUsage(BaseModel):
    input_tokens: int | None = None
    output_tokens: int | None = None
    total_tokens: int | None = None


class MessageOut(APIModel):
    id: uuid.UUID
    conversation_id: uuid.UUID
    seq: int
    role: MessageRole
    content: str
    status: MessageStatus
    provider: str | None
    model: str | None
    usage: TokenUsage | None
    audio_metadata: dict[str, Any] | None
    metadata: dict[str, Any] | None = Field(default=None)
    attachments: list[AttachmentOut] = Field(default_factory=list)
    created_at: datetime
    updated_at: datetime
    edited_at: datetime | None

    @classmethod
    def from_model(cls, message: Message, attachments: Iterable[ConversationAttachment] = ()) -> "MessageOut":
        has_usage = any(
            value is not None for value in (message.input_tokens, message.output_tokens, message.total_tokens)
        )
        return cls(
            id=message.id,
            conversation_id=message.conversation_id,
            seq=message.seq,
            role=message.role,
            content=message.content,
            status=message.status,
            provider=message.provider,
            model=message.model,
            usage=TokenUsage(
                input_tokens=message.input_tokens,
                output_tokens=message.output_tokens,
                total_tokens=message.total_tokens,
            )
            if has_usage
            else None,
            audio_metadata=message.audio_metadata,
            metadata=message.extra,
            attachments=[AttachmentOut.from_model(a) for a in attachments],
            created_at=message.created_at,
            updated_at=message.updated_at,
            edited_at=message.edited_at,
        )


class MessageList(BaseModel):
    items: list[MessageOut]


class MessageEditResult(BaseModel):
    message: MessageOut
    # Editing a user message discards the turns that followed it.
    removed_message_ids: list[uuid.UUID]

"""WebSocket chat protocol (``/api/v1/chat/ws``). See docs/api.md for the full flow.

Client -> server commands are validated here; server -> client events are
plain dicts built by ``ChatService`` and the socket handler.
"""

import uuid
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, TypeAdapter, model_validator

from app.schemas.message import MAX_MESSAGE_CHARS

RequestId = Annotated[str, StringConstraints(min_length=1, max_length=64, pattern=r"^[A-Za-z0-9_\-]+$")]


class _Command(BaseModel):
    model_config = ConfigDict(extra="forbid")


class AuthCommand(_Command):
    type: Literal["auth"]
    token: Annotated[str, StringConstraints(min_length=1, max_length=4096)]


class SendMessageCommand(_Command):
    type: Literal["message.send"]
    request_id: RequestId
    conversation_id: uuid.UUID
    # Text, attachments (uploaded first via POST /attachments), or both.
    content: Annotated[str, StringConstraints(max_length=MAX_MESSAGE_CHARS)] = ""
    attachment_ids: Annotated[list[uuid.UUID], Field(max_length=20)] = Field(default_factory=list)

    @model_validator(mode="after")
    def _text_or_attachments(self) -> "SendMessageCommand":
        if not self.content.strip() and not self.attachment_ids:
            raise ValueError("Send some text or at least one attachment")
        self.attachment_ids = list(dict.fromkeys(self.attachment_ids))  # de-duplicate, keep order
        return self


class RegenerateCommand(_Command):
    type: Literal["response.regenerate"]
    request_id: RequestId
    conversation_id: uuid.UUID


class CancelCommand(_Command):
    type: Literal["response.cancel"]
    request_id: RequestId


class PingCommand(_Command):
    type: Literal["ping"]


ClientCommand = Annotated[
    SendMessageCommand | RegenerateCommand | CancelCommand | PingCommand | AuthCommand,
    Field(discriminator="type"),
]
client_command_adapter: TypeAdapter[ClientCommand] = TypeAdapter(ClientCommand)

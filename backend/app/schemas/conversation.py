import uuid
from datetime import datetime
from typing import Annotated

from pydantic import StringConstraints, model_validator

from app.schemas.common import APIModel, ModelId, ProviderId, RequestModel

Title = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200)]


class ConversationCreate(RequestModel):
    title: Title | None = None
    provider: ProviderId | None = None
    model: ModelId | None = None


class ConversationUpdate(RequestModel):
    title: Title | None = None
    provider: ProviderId | None = None
    model: ModelId | None = None

    @model_validator(mode="after")
    def _validate_fields(self) -> "ConversationUpdate":
        if not self.model_fields_set:
            raise ValueError("Provide at least one field to update")
        if "title" in self.model_fields_set and self.title is None:
            raise ValueError("title cannot be null")
        return self


class ConversationOut(APIModel):
    id: uuid.UUID
    title: str
    provider: str | None
    model: str | None
    created_at: datetime
    updated_at: datetime
    last_message_at: datetime | None


class ConversationPage(APIModel):
    items: list[ConversationOut]
    next_cursor: str | None

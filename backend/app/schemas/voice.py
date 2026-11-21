import uuid
from datetime import datetime
from typing import Annotated, Literal

from pydantic import BaseModel, Field, StringConstraints

from app.schemas.common import ModelId, ProviderId, RequestModel


class VoiceSessionCreate(RequestModel):
    """Start a realtime voice session. Without ``conversation_id`` a new
    conversation is created for the transcript."""

    conversation_id: uuid.UUID | None = None
    provider: ProviderId | None = None
    model: ModelId | None = None


class VoiceSessionOut(BaseModel):
    """Everything the client needs to connect directly to the provider.

    ``client_secret`` is short-lived (see ``expires_at``) and scoped to this one
    session; the server's permanent API key is never returned.
    """

    id: uuid.UUID
    conversation_id: uuid.UUID
    provider: str
    model: str
    transport: Literal["webrtc", "websocket", "relay"]
    endpoint: str
    client_secret: str
    expires_at: datetime
    voice: str | None
    push_to_talk: bool
    # WebRTC providers: the data channel for provider events.
    data_channel: str | None = None
    # WebSocket providers (raw PCM audio): microphone format to send, playback
    # sample rate, and when the session (including reconnects) ends.
    input_audio_format: str | None = None
    output_sample_rate: int | None = None
    session_expires_at: datetime | None = None


class TranscriptCreate(RequestModel):
    role: Literal["user", "assistant"]
    content: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=32_000)]
    # Provider item id: makes retries idempotent.
    item_id: Annotated[str, StringConstraints(min_length=1, max_length=128)] | None = None
    duration_ms: Annotated[int, Field(ge=0, le=3_600_000)] | None = None

"""Provider-independent AI contract.

Every provider adapter (OpenAI Realtime, Gemini Live, ...) implements ``AIProvider``.
Nothing outside ``app/ai_providers/<provider>/`` may import provider SDKs or know
provider-specific wire formats.
"""

import abc
from collections.abc import AsyncIterator
from datetime import datetime
from typing import Any, ClassVar, Literal

from pydantic import BaseModel, Field, SecretStr

# ---------------------------------------------------------------------------
# Capabilities: the UI only offers options that appear here.
# ---------------------------------------------------------------------------


class VoiceOption(BaseModel):
    id: str
    display_name: str
    language_hints: list[str] = Field(default_factory=list)


class NumericRange(BaseModel):
    min: float
    max: float
    default: float


class ProviderCapabilities(BaseModel):
    text_streaming: bool = False
    realtime_voice: bool = False
    server_vad: bool = False
    interruption: bool = False
    image_input: bool = False
    pdf_input: bool = False
    voices: list[VoiceOption] = Field(default_factory=list)
    languages: list[str] = Field(default_factory=list)
    speaking_rate: NumericRange | None = None  # None = provider does not support it


class ModelInfo(BaseModel):
    id: str
    display_name: str
    capabilities: ProviderCapabilities
    is_default: bool = False


# ---------------------------------------------------------------------------
# Text chat
# ---------------------------------------------------------------------------


class ChatAttachment(BaseModel):
    """A file sent with a user turn. Only kinds the model supports are passed."""

    kind: Literal["image", "pdf"]
    mime_type: str
    filename: str
    data: bytes = Field(repr=False)


class ChatTurn(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str
    attachments: list[ChatAttachment] = Field(default_factory=list)


class ChatRequest(BaseModel):
    model: str
    turns: list[ChatTurn]
    temperature: float | None = None
    max_output_tokens: int | None = None
    # Pseudonymous, stable per-user ID for provider abuse monitoring. Never an
    # email or name: the chat service sends a hash of the internal user ID.
    end_user_id: str | None = None


class ChatUsage(BaseModel):
    input_tokens: int | None = None
    output_tokens: int | None = None
    total_tokens: int | None = None


class ChatStreamEvent(BaseModel):
    type: Literal["text_delta", "usage", "done", "error"]
    text: str | None = None
    usage: ChatUsage | None = None
    error_code: str | None = None
    error_message: str | None = None
    provider_metadata: dict[str, Any] | None = None


# ---------------------------------------------------------------------------
# Realtime voice
# ---------------------------------------------------------------------------


class RealtimeSessionRequest(BaseModel):
    model: str
    voice: str | None = None
    # BCP 47 tag of the user's language (improves speech recognition).
    language: str | None = None
    instructions: str | None = None
    # True: the provider detects turns (hands-free, interruptible). False: push-to-talk.
    server_vad: bool = True
    speaking_rate: float | None = None
    end_user_id: str | None = None


class RealtimeSessionDescriptor(BaseModel):
    """What the client needs to open a realtime session. Contains only a
    short-lived credential, never the server's permanent API key."""

    provider: str
    model: str
    transport: Literal["webrtc", "websocket", "relay"]
    endpoint: str
    client_secret: SecretStr
    expires_at: datetime
    config: dict[str, Any] = Field(default_factory=dict)


# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------


class ProviderError(Exception):
    def __init__(self, message: str, *, code: str = "provider_error", retryable: bool = False) -> None:
        super().__init__(message)
        self.code = code
        self.retryable = retryable


class CapabilityNotSupportedError(ProviderError):
    def __init__(self, provider: str, capability: str) -> None:
        super().__init__(f"Provider '{provider}' does not support {capability}", code="capability_not_supported")


# ---------------------------------------------------------------------------
# Adapter interface
# ---------------------------------------------------------------------------


class AIProvider(abc.ABC):
    id: ClassVar[str]
    display_name: ClassVar[str]

    @abc.abstractmethod
    def list_models(self) -> list[ModelInfo]:
        """Models this deployment exposes, with per-model capabilities."""

    @abc.abstractmethod
    def stream_chat(self, request: ChatRequest) -> AsyncIterator[ChatStreamEvent]:
        """Stream a text response. Must end with exactly one ``done`` or ``error`` event."""

    @abc.abstractmethod
    async def create_realtime_session(self, request: RealtimeSessionRequest) -> RealtimeSessionDescriptor:
        """Mint a short-lived client credential for a realtime voice session."""

    async def aclose(self) -> None:  # noqa: B027 - optional hook
        """Release network resources (HTTP clients, sockets)."""

    def get_model(self, model_id: str) -> ModelInfo | None:
        return next((m for m in self.list_models() if m.id == model_id), None)

    def default_model(self) -> ModelInfo | None:
        models = self.list_models()
        return next((m for m in models if m.is_default), models[0] if models else None)

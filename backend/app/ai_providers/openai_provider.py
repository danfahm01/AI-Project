"""OpenAI adapter (text chat via the Responses API).

Verified on 2026-11-20 against the official docs and the official `openai` SDK
(v3.57.0, whose types are generated from OpenAI's OpenAPI spec):

* Endpoint: ``POST /v1/responses`` with ``stream=True``; ``input`` is a list of
  ``{"role": "user"|"assistant"|"system"|"developer", "content": str}``.
* Stream events used here: ``response.output_text.delta`` (``delta``),
  ``response.completed`` (``response.usage``), ``response.incomplete``
  (``response.incomplete_details.reason``), ``response.failed``
  (``response.error.code``/``message``) and ``error`` (``code``/``message``).
* ``store`` defaults to true (responses retained >= 30 days), so it is set to
  false: conversations are persisted by this backend, not by OpenAI.
* Models: https://developers.openai.com/api/docs/models

Realtime voice (verified the same day against the realtime-webrtc,
realtime-conversations and realtime-vad guides, and SDK types):

* The backend mints a short-lived client secret with
  ``POST /v1/realtime/client_secrets`` (``session`` + ``expires_after``;
  response ``value`` + ``expires_at``). The permanent key never leaves the server.
* The client then posts its SDP offer to ``POST /v1/realtime/calls`` with
  ``Authorization: Bearer <client secret>`` and talks over the ``oai-events``
  data channel.
* ``audio.input.turn_detection``: ``semantic_vad`` (hands-free, interruptible) or
  ``null`` (push-to-talk). ``audio.output.speed`` is 0.25-1.5. Voices are listed in
  the realtime-conversations guide.
"""

import base64
import logging
from collections.abc import AsyncIterator
from datetime import UTC, datetime
from typing import Any

import httpx2
from openai import (
    APIConnectionError,
    APIStatusError,
    APITimeoutError,
    AsyncOpenAI,
    AuthenticationError,
    BadRequestError,
    NotFoundError,
    OpenAIError,
    PermissionDeniedError,
    RateLimitError,
)
from pydantic import SecretStr

from app.ai_providers.base import (
    AIProvider,
    CapabilityNotSupportedError,
    ChatRequest,
    ChatStreamEvent,
    ChatTurn,
    ChatUsage,
    ModelInfo,
    NumericRange,
    ProviderCapabilities,
    ProviderError,
    RealtimeSessionDescriptor,
    RealtimeSessionRequest,
    VoiceOption,
)
from app.core.config import Settings

logger = logging.getLogger(__name__)

# Display names for model IDs listed on https://developers.openai.com/api/docs/models
# (2026-11-20). IDs configured via OPENAI_MODELS but not listed here are shown by ID.
KNOWN_MODEL_NAMES: dict[str, str] = {
    "gpt-6.2-astra": "GPT-6.2 Astra",
    "gpt-6.2-sol": "GPT-6.2 Sol",
    "gpt-6-luna": "GPT-6 Luna",
    "gpt-realtime-2.1": "GPT-Realtime-2.1",
}

# Text models whose pages list "Input modalities: text, image" (2026-11-21). PDFs go
# in as `input_file`; the file-inputs guide requires an image-capable model for
# them (text plus page images). Unlisted model IDs get text only.
MULTIMODAL_MODELS = frozenset({"gpt-6.2-astra", "gpt-6.2-sol", "gpt-6-luna"})
TEXT_CHAT_CAPABILITIES = ProviderCapabilities(text_streaming=True)
MULTIMODAL_CHAT_CAPABILITIES = ProviderCapabilities(text_streaming=True, image_input=True, pdf_input=True)

# audio.output.speed: "1.0 is the default speed. 0.25 is the minimum speed. 1.5 is the maximum speed."
REALTIME_SPEED_RANGE = NumericRange(min=0.25, max=1.5, default=1.0)
REALTIME_DATA_CHANNEL = "oai-events"


def _transcription_language(tag: str | None) -> str | None:
    """BCP 47 ("id-ID") -> ISO-639-1 ("id"), as the transcription config expects."""
    if not tag:
        return None
    primary = tag.split("-")[0].lower()
    return primary if len(primary) == 2 else None


def _error_event(code: str, message: str) -> ChatStreamEvent:
    return ChatStreamEvent(type="error", error_code=code, error_message=message)


def map_openai_error(exc: OpenAIError) -> ChatStreamEvent:
    """Translate SDK exceptions into provider-neutral, user-safe errors.

    Raw provider messages may mention account details, so they are logged
    server-side and replaced with neutral text.
    """
    match exc:
        case AuthenticationError() | PermissionDeniedError():
            logger.error("OpenAI rejected the API key: %s", exc)
            return _error_event("provider_auth_failed", "The AI provider rejected this server's credentials.")
        case RateLimitError():
            logger.warning("OpenAI rate limit or quota reached: %s", exc)
            return _error_event("provider_rate_limited", "The AI provider is busy or out of quota. Try again shortly.")
        case NotFoundError():
            logger.error("OpenAI model or endpoint not found: %s", exc)
            return _error_event("provider_model_unavailable", "The selected model is not available.")
        case BadRequestError():
            logger.error("OpenAI rejected the request: %s", exc)
            return _error_event("provider_bad_request", "The AI provider could not process this request.")
        case APITimeoutError():
            return _error_event("provider_timeout", "The AI provider took too long to respond.")
        case APIConnectionError():
            logger.warning("Could not reach OpenAI: %s", exc)
            return _error_event("provider_unavailable", "The AI provider could not be reached.")
        case APIStatusError():
            logger.error("OpenAI returned HTTP %s: %s", exc.status_code, exc)
            return _error_event("provider_unavailable", "The AI provider returned an error. Try again shortly.")
        case _:
            logger.exception("Unexpected OpenAI SDK error", exc_info=exc)
            return _error_event("provider_error", "The AI provider returned an unexpected error.")


class OpenAIProvider(AIProvider):
    id = "openai"
    display_name = "OpenAI"

    def __init__(
        self,
        *,
        api_key: str,
        models: list[str],
        default_model: str,
        base_url: str | None = None,
        timeout_seconds: float = 120,
        max_retries: int = 2,
        http_client: httpx2.AsyncClient | None = None,
        realtime_model: str | None = None,
        realtime_voices: list[str] | None = None,
        realtime_default_voice: str | None = None,
        transcription_model: str = "gpt-realtime-whisper",
        voice_token_ttl_seconds: int = 120,
    ) -> None:
        if not models:
            raise ValueError("OPENAI_MODELS must list at least one model")
        self._models = list(dict.fromkeys(models))  # de-duplicate, keep order
        self._default_model = default_model if default_model in self._models else self._models[0]
        self._realtime_model = realtime_model
        self._voices = list(dict.fromkeys(realtime_voices or []))
        self._default_voice = (
            realtime_default_voice if realtime_default_voice in self._voices else (self._voices or [None])[0]
        )
        self._transcription_model = transcription_model
        self._voice_token_ttl = voice_token_ttl_seconds
        self._client = AsyncOpenAI(
            api_key=api_key,
            base_url=base_url,
            timeout=timeout_seconds,
            max_retries=max_retries,
            http_client=http_client,
        )

    @classmethod
    def from_settings(cls, settings: Settings) -> "OpenAIProvider":
        assert settings.openai_api_key is not None
        return cls(
            api_key=settings.openai_api_key.get_secret_value(),
            models=settings.openai_models,
            default_model=settings.openai_default_model,
            base_url=settings.openai_base_url,
            timeout_seconds=settings.ai_request_timeout_seconds,
            realtime_model=settings.openai_realtime_model,
            realtime_voices=settings.openai_realtime_voices,
            realtime_default_voice=settings.openai_realtime_default_voice,
            transcription_model=settings.openai_realtime_transcription_model,
            voice_token_ttl_seconds=settings.voice_token_ttl_seconds,
        )

    @property
    def realtime_calls_url(self) -> str:
        """Where clients post their WebRTC SDP offer (follows OPENAI_BASE_URL)."""
        return f"{str(self._client.base_url).rstrip('/')}/realtime/calls"

    def list_models(self) -> list[ModelInfo]:
        models = [
            ModelInfo(
                id=model_id,
                display_name=KNOWN_MODEL_NAMES.get(model_id, model_id),
                capabilities=MULTIMODAL_CHAT_CAPABILITIES if model_id in MULTIMODAL_MODELS else TEXT_CHAT_CAPABILITIES,
                is_default=model_id == self._default_model,
            )
            for model_id in self._models
        ]
        if self._realtime_model:
            models.append(
                ModelInfo(
                    id=self._realtime_model,
                    display_name=KNOWN_MODEL_NAMES.get(self._realtime_model, self._realtime_model),
                    capabilities=ProviderCapabilities(
                        realtime_voice=True,
                        server_vad=True,
                        interruption=True,
                        voices=[VoiceOption(id=v, display_name=v.capitalize()) for v in self._voices],
                        speaking_rate=REALTIME_SPEED_RANGE,
                    ),
                )
            )
        return models

    @staticmethod
    def _input_item(turn: ChatTurn) -> dict[str, Any]:
        """A Responses API input message. Attachments become content parts:
        ``input_image`` (base64 data URL, ``detail: auto``) and ``input_file``
        (``filename`` + base64 ``file_data``) as documented in the images-vision
        and file-inputs guides."""
        if not turn.attachments:
            return {"role": turn.role, "content": turn.content}
        content: list[dict[str, Any]] = []
        if turn.content:
            content.append({"type": "input_text", "text": turn.content})
        for attachment in turn.attachments:
            data_url = f"data:{attachment.mime_type};base64,{base64.b64encode(attachment.data).decode()}"
            if attachment.kind == "image":
                content.append({"type": "input_image", "image_url": data_url, "detail": "auto"})
            else:
                content.append({"type": "input_file", "filename": attachment.filename, "file_data": data_url})
        return {"role": turn.role, "content": content}

    def _build_params(self, request: ChatRequest) -> dict[str, Any]:
        instructions = "\n\n".join(t.content for t in request.turns if t.role == "system")
        params: dict[str, Any] = {
            "model": request.model,
            "input": [self._input_item(t) for t in request.turns if t.role != "system"],
            "stream": True,
            "store": False,
        }
        if instructions:
            params["instructions"] = instructions
        if request.max_output_tokens is not None:
            params["max_output_tokens"] = request.max_output_tokens
        if request.temperature is not None:
            params["temperature"] = request.temperature
        if request.end_user_id:
            params["safety_identifier"] = request.end_user_id
        return params

    async def stream_chat(self, request: ChatRequest) -> AsyncIterator[ChatStreamEvent]:
        try:
            stream = await self._client.responses.create(**self._build_params(request))
        except OpenAIError as exc:
            yield map_openai_error(exc)
            return

        try:
            async for event in stream:
                match event.type:
                    case "response.output_text.delta":
                        if event.delta:
                            yield ChatStreamEvent(type="text_delta", text=event.delta)
                    case "response.completed" | "response.incomplete":
                        response = event.response
                        if response.usage is not None:
                            yield ChatStreamEvent(
                                type="usage",
                                usage=ChatUsage(
                                    input_tokens=response.usage.input_tokens,
                                    output_tokens=response.usage.output_tokens,
                                    total_tokens=response.usage.total_tokens,
                                ),
                            )
                        metadata: dict[str, Any] = {"response_id": response.id}
                        if event.type == "response.incomplete" and response.incomplete_details is not None:
                            # e.g. max_output_tokens or content_filter: keep the partial answer.
                            metadata["incomplete_reason"] = response.incomplete_details.reason
                        yield ChatStreamEvent(type="done", provider_metadata=metadata)
                        return
                    case "response.failed":
                        error = event.response.error
                        logger.error("OpenAI response failed: %s", error)
                        yield _error_event(
                            "provider_rate_limited"
                            if error is not None and error.code == "rate_limit_exceeded"
                            else "provider_failed",
                            "The AI provider could not complete the response.",
                        )
                        return
                    case "error":
                        logger.error("OpenAI stream error %s: %s", event.code, event.message)
                        yield _error_event("provider_error", "The AI provider reported an error during the response.")
                        return
                    case _:
                        pass  # created/in_progress/output_item/... events carry nothing we need
            yield _error_event("provider_stream_interrupted", "The AI provider closed the stream unexpectedly.")
        except OpenAIError as exc:
            yield map_openai_error(exc)
        finally:
            await stream.close()

    def build_realtime_session(self, request: RealtimeSessionRequest) -> dict[str, Any]:
        """The ``session`` object for ``POST /v1/realtime/client_secrets``."""
        voice = request.voice if request.voice in self._voices else self._default_voice
        transcription: dict[str, Any] = {"model": self._transcription_model}
        if language := _transcription_language(request.language):
            transcription["language"] = language
        output: dict[str, Any] = {}
        if voice:
            output["voice"] = voice
        if request.speaking_rate is not None:
            output["speed"] = min(REALTIME_SPEED_RANGE.max, max(REALTIME_SPEED_RANGE.min, request.speaking_rate))
        session: dict[str, Any] = {
            "type": "realtime",
            "model": request.model,
            "audio": {
                "input": {
                    "transcription": transcription,
                    # Hands-free: semantic VAD ends turns and lets the user interrupt.
                    # Push-to-talk: no turn detection; the client commits each turn.
                    "turn_detection": (
                        {
                            "type": "semantic_vad",
                            "eagerness": "auto",
                            "create_response": True,
                            "interrupt_response": True,
                        }
                        if request.server_vad
                        else None
                    ),
                },
                "output": output,
            },
        }
        if request.instructions:
            session["instructions"] = request.instructions
        return session

    async def create_realtime_session(self, request: RealtimeSessionRequest) -> RealtimeSessionDescriptor:
        if not self._realtime_model or request.model != self._realtime_model:
            raise CapabilityNotSupportedError(self.id, f"realtime voice with model '{request.model}'")
        session = self.build_realtime_session(request)
        try:
            secret = await self._client.realtime.client_secrets.create(
                session=session,  # type: ignore[arg-type]
                expires_after={"anchor": "created_at", "seconds": self._voice_token_ttl},
                extra_headers={"OpenAI-Safety-Identifier": request.end_user_id} if request.end_user_id else None,
            )
        except OpenAIError as exc:
            event = map_openai_error(exc)
            raise ProviderError(
                event.error_message or "Could not start the voice session.",
                code=event.error_code or "provider_error",
                retryable=event.error_code in {"provider_rate_limited", "provider_timeout", "provider_unavailable"},
            ) from exc

        return RealtimeSessionDescriptor(
            provider=self.id,
            model=request.model,
            transport="webrtc",
            endpoint=self.realtime_calls_url,
            client_secret=SecretStr(secret.value),
            expires_at=datetime.fromtimestamp(secret.expires_at, UTC),
            config={
                "voice": session["audio"]["output"].get("voice"),
                "turn_detection": "semantic_vad" if request.server_vad else "none",
                "data_channel": REALTIME_DATA_CHANNEL,
            },
        )

    async def aclose(self) -> None:
        await self._client.close()

"""Google Gemini adapter: text chat (Gemini API) and realtime voice (Live API).

Verified on 2026-11-21 against the official docs (aistudio.google.com/docs: models,
changelog, live-api/ephemeral-tokens, live-api/capabilities,
live-api/get-started-websocket, speech-generation) and the official ``google-genai``
SDK v3.6.1 (its types and request converters):

Text chat
* ``client.aio.models.generate_content_stream`` ->
  ``POST /{version}/models/{model}:streamGenerateContent?alt=sse``. History is a list
  of ``Content(role="user"|"model")``; system turns go to ``system_instruction``.
* Paid-tier projects store Generate Content requests by default since 2026-10-26;
  ``store=False`` opts out per request (conversations are stored by this backend).
* Chunks carry ``candidates[0].content.parts[].text``, ``finish_reason`` on the last
  chunk, ``usage_metadata`` and ``prompt_feedback.block_reason``.
* Errors: HTTP 4xx -> ``errors.ClientError``, 5xx -> ``errors.ServerError`` (``code``,
  ``status``, ``message``); network failures are raised as ``httpx2`` exceptions.
* Gemini 3.6+ ignores custom sampling parameters, so none are sent. There is no
  end-user identifier field, so none is sent either.

Realtime voice (Live API)
* The backend mints an ephemeral token: ``client.aio.auth_tokens.create`` ->
  ``POST /v1beta/auth_tokens`` with ``uses=1``, ``new_session_expire_time`` (window
  to connect), ``expire_time`` (end of the session; reconnecting with session
  resumption reuses the token) and ``live_connect_constraints`` (model + config).
  Without ``lock_additional_fields`` the whole configuration is locked, so the client
  cannot change the model, system instruction, voice or turn detection.
* The client connects to
  ``wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained?access_token=<token>``.
* Audio: input raw 16-bit little-endian PCM (``audio/pcm;rate=16000``), output 16-bit
  PCM at 24 kHz. Native-audio models choose the language themselves (no
  ``language_code``) and have no speaking-rate parameter.
* Turn detection: automatic VAD by default (the user can interrupt). Push-to-talk
  disables it; the client sends ``activityStart`` / ``activityEnd``.
"""

import logging
import warnings
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from typing import Any
from urllib.parse import urlsplit, urlunsplit

import httpx2
from google import genai
from google.genai import errors as genai_errors
from google.genai import types
from pydantic import SecretStr

from app.ai_providers.base import (
    AIProvider,
    CapabilityNotSupportedError,
    ChatRequest,
    ChatStreamEvent,
    ChatUsage,
    ModelInfo,
    ProviderCapabilities,
    ProviderError,
    RealtimeSessionDescriptor,
    RealtimeSessionRequest,
    VoiceOption,
)
from app.core.config import Settings

logger = logging.getLogger(__name__)

# auth_tokens.create warns on every call that the SDK's token support is
# experimental (the Live API marks ephemeral tokens as preview). This is known
# and documented, so the per-request warning is not useful in the logs.
warnings.filterwarnings("ignore", message="The SDK's token creation implementation is experimental")

DEFAULT_BASE_URL = "https://generativelanguage.googleapis.com/"

# Display names for model IDs listed on https://aistudio.google.com/docs/models
# (2026-11-21). IDs configured via GEMINI_MODELS but not listed here are shown by ID.
KNOWN_MODEL_NAMES: dict[str, str] = {
    "gemini-4-carbon": "Gemini 4 Carbon",
    "gemini-4-hydrogen": "Gemini 4 Hydrogen",
    "gemini-4-neon": "Gemini 4 Neon",
    "gemini-4-argon": "Gemini 4 Argon",
    "gemini-3.8-flash": "Gemini 3.8 Flash",
    "gemini-3.6-flash": "Gemini 3.6 Flash",
    "gemini-3.5-flash-lite": "Gemini 3.5 Flash-Lite",
    "gemini-3.8-live": "Gemini 3.8 Live",
}

# Voice styles from the speech-generation guide's "Voice options" (2026-11-21).
VOICE_STYLES: dict[str, str] = {
    "Zephyr": "Bright",
    "Puck": "Upbeat",
    "Charon": "Informative",
    "Kore": "Firm",
    "Fenrir": "Excitable",
    "Leda": "Youthful",
    "Orus": "Firm",
    "Aoede": "Breezy",
    "Callirrhoe": "Easy-going",
    "Autonoe": "Bright",
    "Enceladus": "Breathy",
    "Iapetus": "Clear",
    "Umbriel": "Easy-going",
    "Algieba": "Smooth",
    "Despina": "Smooth",
    "Erinome": "Clear",
    "Algenib": "Gravelly",
    "Rasalgethi": "Informative",
    "Laomedeia": "Upbeat",
    "Achernar": "Soft",
    "Alnilam": "Firm",
    "Schedar": "Even",
    "Gacrux": "Mature",
    "Pulcherrima": "Forward",
    "Achird": "Friendly",
    "Zubenelgenubi": "Casual",
    "Vindemiatrix": "Gentle",
    "Sadachbia": "Lively",
    "Sadaltager": "Knowledgeable",
    "Sulafat": "Warm",
}

# Text models whose pages list "Inputs: Text, Image, Video, Audio, and PDF"
# (2026-11-21); this app sends images and PDFs. Unlisted model IDs get text only.
MULTIMODAL_MODELS = frozenset(
    {
        "gemini-4-carbon",
        "gemini-4-hydrogen",
        "gemini-4-neon",
        "gemini-4-argon",
        "gemini-3.8-flash",
        "gemini-3.6-flash",
        "gemini-3.5-flash-lite",
    }
)
TEXT_CHAT_CAPABILITIES = ProviderCapabilities(text_streaming=True)
MULTIMODAL_CHAT_CAPABILITIES = ProviderCapabilities(text_streaming=True, image_input=True, pdf_input=True)

LIVE_INPUT_SAMPLE_RATE = 16_000
LIVE_OUTPUT_SAMPLE_RATE = 24_000
LIVE_INPUT_MIME_TYPE = f"audio/pcm;rate={LIVE_INPUT_SAMPLE_RATE}"

# Finish reasons that mean the output was filtered (the partial text is kept).
_FILTERED_FINISH_REASONS = {
    "SAFETY",
    "RECITATION",
    "BLOCKLIST",
    "PROHIBITED_CONTENT",
    "SPII",
    "MODEL_ARMOR",
    "LANGUAGE",
}


def _error_event(code: str, message: str) -> ChatStreamEvent:
    return ChatStreamEvent(type="error", error_code=code, error_message=message)


def map_gemini_error(exc: Exception) -> ChatStreamEvent:
    """Translate SDK/transport exceptions into provider-neutral, user-safe errors.

    Raw provider messages are logged server-side, never shown to users.
    """
    if isinstance(exc, genai_errors.APIError):
        code, status = exc.code, (exc.status or "")
        logger.error("Gemini API error %s %s: %s", code, status, exc.message)
        # An invalid key is reported as 400 INVALID_ARGUMENT ("API key not valid").
        if code in (401, 403) or "API key" in (exc.message or "") or status == "PERMISSION_DENIED":
            return _error_event("provider_auth_failed", "The AI provider rejected this server's credentials.")
        if code == 429 or status == "RESOURCE_EXHAUSTED":
            return _error_event("provider_rate_limited", "The AI provider is busy or out of quota. Try again shortly.")
        if code == 404:
            return _error_event("provider_model_unavailable", "The selected model is not available.")
        if code in (408, 504):
            return _error_event("provider_timeout", "The AI provider took too long to respond.")
        if isinstance(exc, genai_errors.ClientError):
            return _error_event("provider_bad_request", "The AI provider could not process this request.")
        return _error_event("provider_unavailable", "The AI provider returned an error. Try again shortly.")
    if isinstance(exc, httpx2.TimeoutException):
        return _error_event("provider_timeout", "The AI provider took too long to respond.")
    if isinstance(exc, httpx2.HTTPError):
        logger.warning("Could not reach Gemini: %s", exc)
        return _error_event("provider_unavailable", "The AI provider could not be reached.")
    logger.exception("Unexpected Gemini SDK error", exc_info=exc)
    return _error_event("provider_error", "The AI provider returned an unexpected error.")


def _enum_name(value: Any) -> str | None:
    if value is None:
        return None
    return str(getattr(value, "value", value))


class GeminiProvider(AIProvider):
    id = "gemini"
    display_name = "Google Gemini"

    def __init__(
        self,
        *,
        api_key: str,
        models: list[str],
        default_model: str,
        base_url: str | None = None,
        api_version: str = "v1beta",
        timeout_seconds: float = 120,
        http_client: httpx2.AsyncClient | None = None,
        live_model: str | None = None,
        live_voices: list[str] | None = None,
        live_default_voice: str | None = None,
        voice_token_ttl_seconds: int = 120,
        voice_session_max_seconds: int = 1800,
    ) -> None:
        if not models:
            raise ValueError("GEMINI_MODELS must list at least one model")
        self._models = list(dict.fromkeys(models))
        self._default_model = default_model if default_model in self._models else self._models[0]
        self._live_model = live_model
        self._voices = list(dict.fromkeys(live_voices or []))
        self._default_voice = live_default_voice if live_default_voice in self._voices else (self._voices or [None])[0]
        self._voice_token_ttl = voice_token_ttl_seconds
        self._voice_session_max = voice_session_max_seconds
        self._base_url = base_url or DEFAULT_BASE_URL
        self._api_version = api_version
        options = types.HttpOptions(
            base_url=self._base_url,
            api_version=api_version,
            timeout=int(timeout_seconds * 1000),  # milliseconds
            httpx_async_client=http_client,
        )
        # vertexai=False: never switch to Vertex AI because of environment variables.
        self._client = genai.Client(api_key=api_key, vertexai=False, http_options=options)

    @classmethod
    def from_settings(cls, settings: Settings) -> "GeminiProvider":
        assert settings.gemini_api_key is not None
        return cls(
            api_key=settings.gemini_api_key.get_secret_value(),
            models=settings.gemini_models,
            default_model=settings.gemini_default_model,
            base_url=settings.gemini_base_url,
            api_version=settings.gemini_api_version,
            timeout_seconds=settings.ai_request_timeout_seconds,
            live_model=settings.gemini_live_model,
            live_voices=settings.gemini_live_voices,
            live_default_voice=settings.gemini_live_default_voice,
            voice_token_ttl_seconds=settings.voice_token_ttl_seconds,
            voice_session_max_seconds=settings.voice_session_max_seconds,
        )

    # ------------------------------------------------------------------ catalog

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
        if self._live_model:
            models.append(
                ModelInfo(
                    id=self._live_model,
                    display_name=KNOWN_MODEL_NAMES.get(self._live_model, self._live_model),
                    capabilities=ProviderCapabilities(
                        realtime_voice=True,
                        server_vad=True,
                        interruption=True,
                        voices=[
                            VoiceOption(id=v, display_name=f"{v} ({VOICE_STYLES[v]})" if v in VOICE_STYLES else v)
                            for v in self._voices
                        ],
                        # No speaking-rate parameter for native audio output.
                        speaking_rate=None,
                    ),
                )
            )
        return models

    # ------------------------------------------------------------------ text chat

    def build_chat_request(self, request: ChatRequest) -> tuple[list[types.Content], types.GenerateContentConfig]:
        system = "\n\n".join(t.content for t in request.turns if t.role == "system")
        contents: list[types.Content] = []
        for turn in request.turns:
            if turn.role == "system":
                continue
            # Text first, then files (the image guide places the prompt before the image).
            parts = [types.Part(text=turn.content)] if turn.content or not turn.attachments else []
            parts += [types.Part.from_bytes(data=a.data, mime_type=a.mime_type) for a in turn.attachments]
            contents.append(types.Content(role="model" if turn.role == "assistant" else "user", parts=parts))
        config = types.GenerateContentConfig(
            system_instruction=system or None,
            max_output_tokens=request.max_output_tokens,
            store=False,
        )
        return contents, config

    async def stream_chat(self, request: ChatRequest) -> AsyncIterator[ChatStreamEvent]:
        contents, config = self.build_chat_request(request)
        produced_text = False
        usage: ChatUsage | None = None
        finish_reason: str | None = None
        response_id: str | None = None
        model_version: str | None = None
        try:
            stream = await self._client.aio.models.generate_content_stream(
                model=request.model, contents=contents, config=config
            )
            async for chunk in stream:
                response_id = chunk.response_id or response_id
                model_version = chunk.model_version or model_version
                if chunk.prompt_feedback is not None and chunk.prompt_feedback.block_reason is not None:
                    logger.warning("Gemini blocked the prompt: %s", _enum_name(chunk.prompt_feedback.block_reason))
                    yield _error_event("provider_content_blocked", "The AI provider declined to answer this request.")
                    return
                if chunk.usage_metadata is not None:
                    meta = chunk.usage_metadata
                    output = (meta.candidates_token_count or 0) + (meta.thoughts_token_count or 0)
                    usage = ChatUsage(
                        input_tokens=meta.prompt_token_count,
                        output_tokens=output or None,
                        total_tokens=meta.total_token_count,
                    )
                for candidate in chunk.candidates or []:
                    for part in (candidate.content.parts if candidate.content else None) or []:
                        if part.text and not part.thought:
                            produced_text = True
                            yield ChatStreamEvent(type="text_delta", text=part.text)
                    if candidate.finish_reason is not None:
                        finish_reason = _enum_name(candidate.finish_reason)
                    break  # one candidate is requested
        except Exception as exc:  # SDK errors and httpx2 transport errors
            yield map_gemini_error(exc)
            return

        if finish_reason is None:
            yield _error_event("provider_stream_interrupted", "The AI provider closed the stream unexpectedly.")
            return
        metadata: dict[str, Any] = {}
        if response_id:
            metadata["response_id"] = response_id
        if model_version:
            metadata["model_version"] = model_version
        if finish_reason == "MAX_TOKENS":
            metadata["incomplete_reason"] = "max_output_tokens"
        elif finish_reason in _FILTERED_FINISH_REASONS:
            logger.warning("Gemini stopped the response: %s", finish_reason)
            if not produced_text:
                yield _error_event("provider_content_blocked", "The AI provider declined to answer this request.")
                return
            metadata["incomplete_reason"] = "content_filter"
        elif finish_reason != "STOP":
            logger.warning("Gemini finished with reason %s", finish_reason)
            if not produced_text:
                yield _error_event("provider_failed", "The AI provider could not complete the response.")
                return
            metadata["incomplete_reason"] = finish_reason.lower()
        if usage is not None:
            yield ChatStreamEvent(type="usage", usage=usage)
        yield ChatStreamEvent(type="done", provider_metadata=metadata)

    # ------------------------------------------------------------------ realtime voice

    @property
    def live_websocket_url(self) -> str:
        """Live API endpoint for ephemeral tokens (follows GEMINI_BASE_URL)."""
        parts = urlsplit(self._base_url)
        scheme = {"https": "wss", "http": "ws"}.get(parts.scheme, parts.scheme)
        path = (
            f"{parts.path.rstrip('/')}/ws/google.ai.generativelanguage."
            f"{self._api_version}.GenerativeService.BidiGenerateContentConstrained"
        )
        return urlunsplit((scheme, parts.netloc, path, "", ""))

    def build_live_config(self, request: RealtimeSessionRequest) -> types.LiveConnectConfig:
        voice = request.voice if request.voice in self._voices else self._default_voice
        config = types.LiveConnectConfig(
            response_modalities=[types.Modality.AUDIO],
            system_instruction=request.instructions or None,
            input_audio_transcription=types.AudioTranscriptionConfig(),
            output_audio_transcription=types.AudioTranscriptionConfig(),
            # Reconnect after the ~10 minute connection limit without losing context.
            session_resumption=types.SessionResumptionConfig(),
            # Lets audio sessions run past the 15 minute limit.
            context_window_compression=types.ContextWindowCompressionConfig(sliding_window=types.SlidingWindow()),
        )
        if voice:
            config.speech_config = types.SpeechConfig(
                voice_config=types.VoiceConfig(prebuilt_voice_config=types.PrebuiltVoiceConfig(voice_name=voice))
            )
        if not request.server_vad:
            # Push-to-talk: the client marks each turn with activityStart/activityEnd.
            config.realtime_input_config = types.RealtimeInputConfig(
                automatic_activity_detection=types.AutomaticActivityDetection(disabled=True)
            )
        return config

    async def create_realtime_session(self, request: RealtimeSessionRequest) -> RealtimeSessionDescriptor:
        if not self._live_model or request.model != self._live_model:
            raise CapabilityNotSupportedError(self.id, f"realtime voice with model '{request.model}'")
        live_config = self.build_live_config(request)
        now = datetime.now(UTC)
        connect_by = now + timedelta(seconds=self._voice_token_ttl)
        session_end = now + timedelta(seconds=max(self._voice_session_max, self._voice_token_ttl))
        try:
            token = await self._client.aio.auth_tokens.create(
                config=types.CreateAuthTokenConfig(
                    uses=1,
                    new_session_expire_time=connect_by,
                    expire_time=session_end,
                    live_connect_constraints=types.LiveConnectConstraints(model=request.model, config=live_config),
                )
            )
        except Exception as exc:
            event = map_gemini_error(exc)
            raise ProviderError(
                event.error_message or "Could not start the voice session.",
                code=event.error_code or "provider_error",
                retryable=event.error_code in {"provider_rate_limited", "provider_timeout", "provider_unavailable"},
            ) from exc
        if not token.name:
            raise ProviderError("The AI provider returned no session token.", code="provider_failed")

        voice = None
        if live_config.speech_config and live_config.speech_config.voice_config:
            prebuilt = live_config.speech_config.voice_config.prebuilt_voice_config
            voice = prebuilt.voice_name if prebuilt else None
        return RealtimeSessionDescriptor(
            provider=self.id,
            model=request.model,
            transport="websocket",
            endpoint=self.live_websocket_url,
            client_secret=SecretStr(token.name),
            expires_at=_as_utc(token.new_session_expire_time) or connect_by,
            config={
                "voice": voice,
                "turn_detection": "server_vad" if request.server_vad else "none",
                "session_expires_at": _as_utc(token.expire_time) or session_end,
                "input_audio_format": LIVE_INPUT_MIME_TYPE,
                "output_sample_rate": LIVE_OUTPUT_SAMPLE_RATE,
            },
        )

    async def aclose(self) -> None:
        await self._client.aio.aclose()


def _as_utc(value: datetime | str | None) -> datetime | None:
    """Token times arrive as datetimes or, depending on the SDK path, ISO strings."""
    if value is None:
        return None
    if isinstance(value, str):
        try:
            value = datetime.fromisoformat(value.replace("Z", "+00:00"))
        except ValueError:
            return None
    return value if value.tzinfo is not None else value.replace(tzinfo=UTC)

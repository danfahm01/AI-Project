"""Anthropic Claude adapter: streaming text chat (Messages API).

Built on the official ``anthropic`` Python SDK 2.12.0, following Anthropic's
claude-api guide (model table cached 2026-11-03):

* ``client.beta.messages.stream`` -> ``POST /v1/messages?beta=true`` with
  ``stream: true``. System turns go to the top-level ``system``; the history is a list
  of ``user`` / ``assistant`` messages that starts with a user message. Images are
  base64 ``image`` blocks and PDFs base64 ``document`` blocks, placed before the text.
* Current models think adaptively (on by default, and Opus 5.5 cannot turn it off).
  Thinking is not displayed by default, so thinking blocks carry no text; only text
  deltas reach the user. No sampling parameters are sent (rejected since API
  version 2026-10-21).
* Refusals end with ``stop_reason: "refusal"``. For the models that support it, the
  server-side fallback (beta ``server-side-fallback-2026-07-01``, ``fallbacks:
  "default"``) re-runs a refused request on a fallback model in the same call.
* Top-level ``cache_control`` caches the conversation prefix between turns
  (a prefix below the model's minimum is simply not cached).
* ``metadata.user_id`` carries the pseudonymous per-user ID for abuse monitoring.
* Errors are typed SDK exceptions (``AuthenticationError``, ``RateLimitError``,
  ``OverloadedError``, ...); network failures are ``APIConnectionError`` /
  ``APITimeoutError``. The SDK retries 408/409/429/5xx itself (twice) before a
  stream starts.
* There is no realtime voice API: voice mode uses Gemini or OpenAI.
"""

import base64
import logging
from collections.abc import AsyncIterator
from typing import Any

import anthropic
import httpx2

from app.ai_providers.base import (
    AIProvider,
    CapabilityNotSupportedError,
    ChatAttachment,
    ChatRequest,
    ChatStreamEvent,
    ChatUsage,
    ModelInfo,
    ProviderCapabilities,
    RealtimeSessionDescriptor,
    RealtimeSessionRequest,
)
from app.core.config import Settings

logger = logging.getLogger(__name__)

# Display names for the current models (claude-api model table, 2026-11-03).
# IDs configured via ANTHROPIC_MODELS but not listed here are shown by ID.
KNOWN_MODEL_NAMES: dict[str, str] = {
    "claude-fable-5-2": "Claude Fable 5.2",
    "claude-opus-5-5": "Claude Opus 5.5",
    "claude-opus-5": "Claude Opus 5",
    "claude-sonnet-5-5": "Claude Sonnet 5.5",
    "claude-sonnet-5": "Claude Sonnet 5",
    "claude-haiku-5-5": "Claude Haiku 5.5",
}

# Models that accept the server-side refusal fallback ("default" routing).
FALLBACK_MODELS = frozenset(
    {"claude-fable-5-2", "claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"}
)
FALLBACK_BETA = "server-side-fallback-2026-07-01"

# Every current Claude model reads images and PDFs.
CHAT_CAPABILITIES = ProviderCapabilities(text_streaming=True, image_input=True, pdf_input=True)

# Streaming has no HTTP timeout concern, so the model gets room for long answers.
DEFAULT_MAX_TOKENS = 64_000


def _error_event(code: str, message: str) -> ChatStreamEvent:
    return ChatStreamEvent(type="error", error_code=code, error_message=message)


_MESSAGES: dict[str, str] = {
    "provider_out_of_credit": (
        "The Claude account has no API credit left or reached its spend limit. Add credit at platform.claude.com."
    ),
    "provider_auth_failed": "The AI provider rejected this server's credentials.",
    "provider_rate_limited": "The AI provider is busy or out of quota. Try again shortly.",
    "provider_model_unavailable": "The selected model is not available.",
    "provider_timeout": "The AI provider took too long to respond.",
    "provider_unavailable": "The AI provider returned an error. Try again shortly.",
    "provider_bad_request": "The AI provider could not process this request.",
}
# The API's error types (also sent as "error" events in the middle of a stream,
# where the HTTP status is still 200).
_TYPE_CODES: dict[str, str] = {
    "authentication_error": "provider_auth_failed",
    "permission_error": "provider_auth_failed",
    "billing_error": "provider_out_of_credit",
    "rate_limit_error": "provider_rate_limited",
    "overloaded_error": "provider_rate_limited",
    "not_found_error": "provider_model_unavailable",
    "timeout_error": "provider_timeout",
    "api_error": "provider_unavailable",
}
_STATUS_CODES: dict[int, str] = {
    401: "provider_auth_failed",
    402: "provider_out_of_credit",
    403: "provider_auth_failed",
    404: "provider_model_unavailable",
    408: "provider_timeout",
    429: "provider_rate_limited",
    504: "provider_timeout",
    529: "provider_rate_limited",
}


def _error_type(exc: anthropic.APIStatusError) -> str | None:
    body = exc.body
    error = body.get("error") if isinstance(body, dict) else None
    kind = error.get("type") if isinstance(error, dict) else None
    return kind if isinstance(kind, str) else None


def _status_error_code(exc: anthropic.APIStatusError) -> str:
    if isinstance(exc, anthropic.EnforcedSpendLimitReachedError | anthropic.ContractSpendLimitReachedError):
        return "provider_out_of_credit"
    if "credit balance" in str(exc.message or "").lower():
        return "provider_out_of_credit"
    code = _TYPE_CODES.get(_error_type(exc) or "") or _STATUS_CODES.get(exc.status_code)
    if code:
        return code
    return "provider_unavailable" if exc.status_code >= 500 else "provider_bad_request"


def map_anthropic_error(exc: Exception) -> ChatStreamEvent:
    """Translate SDK exceptions into provider-neutral, user-safe errors.

    Raw provider messages are logged server-side, never shown to users.
    """
    if isinstance(exc, anthropic.APIStatusError):
        request_id = getattr(exc, "request_id", None)
        logger.error("Anthropic API error %s (request %s): %s", exc.status_code, request_id, exc.message)
        code = _status_error_code(exc)
        return _error_event(code, _MESSAGES[code])
    if isinstance(exc, anthropic.APITimeoutError):
        return _error_event("provider_timeout", "The AI provider took too long to respond.")
    if isinstance(exc, anthropic.APIConnectionError):
        logger.warning("Could not reach Anthropic: %s", exc)
        return _error_event("provider_unavailable", "The AI provider could not be reached.")
    logger.exception("Unexpected Anthropic SDK error", exc_info=exc)
    return _error_event("provider_error", "The AI provider returned an unexpected error.")


def _file_block(attachment: ChatAttachment) -> dict[str, Any]:
    source = {
        "type": "base64",
        "media_type": attachment.mime_type,
        "data": base64.standard_b64encode(attachment.data).decode("ascii"),
    }
    return {"type": "image" if attachment.kind == "image" else "document", "source": source}


class AnthropicProvider(AIProvider):
    id = "anthropic"
    display_name = "Anthropic Claude"

    def __init__(
        self,
        *,
        api_key: str,
        models: list[str],
        default_model: str,
        base_url: str | None = None,
        timeout_seconds: float = 120,
        http_client: httpx2.AsyncClient | None = None,
        max_retries: int = 2,
    ) -> None:
        if not models:
            raise ValueError("ANTHROPIC_MODELS must list at least one model")
        self._models = list(dict.fromkeys(models))
        self._default_model = default_model if default_model in self._models else self._models[0]
        # Streaming: the timeout bounds the connection and each gap between events
        # (the API sends pings while the model thinks), not the whole answer.
        self._client = anthropic.AsyncAnthropic(
            api_key=api_key,
            base_url=base_url,
            timeout=timeout_seconds,
            http_client=http_client,
            max_retries=max_retries,
        )

    @classmethod
    def from_settings(cls, settings: Settings) -> "AnthropicProvider":
        assert settings.anthropic_api_key is not None
        return cls(
            api_key=settings.anthropic_api_key.get_secret_value(),
            models=settings.anthropic_models,
            default_model=settings.anthropic_default_model,
            base_url=settings.anthropic_base_url,
            timeout_seconds=settings.ai_request_timeout_seconds,
        )

    # ------------------------------------------------------------------ catalog

    def list_models(self) -> list[ModelInfo]:
        return [
            ModelInfo(
                id=model_id,
                display_name=KNOWN_MODEL_NAMES.get(model_id, model_id),
                capabilities=CHAT_CAPABILITIES,
                is_default=model_id == self._default_model,
            )
            for model_id in self._models
        ]

    # ------------------------------------------------------------------ text chat

    def build_chat_params(self, request: ChatRequest) -> dict[str, Any]:
        system = "\n\n".join(t.content for t in request.turns if t.role == "system" and t.content)
        messages: list[dict[str, Any]] = []
        for turn in request.turns:
            if turn.role == "system" or not (turn.content or turn.attachments):
                continue  # the API rejects empty text blocks
            if turn.role == "assistant" and not messages:
                continue  # the conversation must start with a user message
            if turn.attachments:
                content: str | list[dict[str, Any]] = [_file_block(a) for a in turn.attachments]
                if turn.content:
                    content.append({"type": "text", "text": turn.content})
            else:
                content = turn.content
            messages.append({"role": turn.role, "content": content})

        params: dict[str, Any] = {
            "model": request.model,
            "max_tokens": request.max_output_tokens or DEFAULT_MAX_TOKENS,
            "messages": messages,
            "cache_control": {"type": "ephemeral"},
        }
        if system:
            params["system"] = system
        if request.end_user_id:
            params["metadata"] = {"user_id": request.end_user_id}
        if request.model in FALLBACK_MODELS:
            params["betas"] = [FALLBACK_BETA]
            params["fallbacks"] = "default"
        return params

    async def stream_chat(self, request: ChatRequest) -> AsyncIterator[ChatStreamEvent]:
        params = self.build_chat_params(request)
        produced_text = False
        try:
            async with self._client.beta.messages.stream(**params) as stream:
                async for event in stream:
                    if event.type == "text" and event.text:
                        produced_text = True
                        yield ChatStreamEvent(type="text_delta", text=event.text)
                final = await stream.get_final_message()
        except Exception as exc:  # typed SDK errors, network errors
            yield map_anthropic_error(exc)
            return

        stop_reason = final.stop_reason
        if stop_reason is None:
            yield _error_event("provider_stream_interrupted", "The AI provider closed the stream unexpectedly.")
            return
        metadata: dict[str, Any] = {"response_id": final.id, "model_version": final.model}
        if stop_reason == "max_tokens":
            metadata["incomplete_reason"] = "max_output_tokens"
        elif stop_reason == "refusal":
            category = getattr(getattr(final, "stop_details", None), "category", None)
            logger.warning("Claude declined the request (category %s)", category)
            if not produced_text:
                yield _error_event("provider_content_blocked", "The AI provider declined to answer this request.")
                return
            metadata["incomplete_reason"] = "content_filter"
        elif stop_reason not in ("end_turn", "stop_sequence"):
            logger.warning("Claude finished with stop reason %s", stop_reason)
            if not produced_text:
                yield _error_event("provider_failed", "The AI provider could not complete the response.")
                return
            metadata["incomplete_reason"] = str(stop_reason)

        usage = final.usage
        if usage is not None:
            # input_tokens counts only the uncached part of the prompt.
            prompt = (
                (usage.input_tokens or 0)
                + (usage.cache_creation_input_tokens or 0)
                + (usage.cache_read_input_tokens or 0)
            )
            yield ChatStreamEvent(
                type="usage",
                usage=ChatUsage(
                    input_tokens=prompt,
                    output_tokens=usage.output_tokens,
                    total_tokens=prompt + (usage.output_tokens or 0),
                ),
            )
        yield ChatStreamEvent(type="done", provider_metadata=metadata)

    # ------------------------------------------------------------------ realtime voice

    async def create_realtime_session(self, request: RealtimeSessionRequest) -> RealtimeSessionDescriptor:
        raise CapabilityNotSupportedError(self.id, "realtime voice")

    async def aclose(self) -> None:
        await self._client.close()

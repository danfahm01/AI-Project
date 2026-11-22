"""Ollama adapter: text chat with models that run on this computer (no API key).

Verified on 2026-11-22 against the official docs (docs.ollama.com: api/chat,
api/tags, api/show, api/streaming, api/errors, capabilities/thinking, windows)
and the OpenAPI spec they are generated from (docs.ollama.com/openapi.yaml):

* ``GET /api/tags`` lists the installed models (``models[].name``, ``digest``).
* ``POST /api/show`` ``{"model": name}`` returns ``capabilities``, for example
  ``completion``, ``vision``, ``thinking``, ``embedding``.
* ``POST /api/chat`` with ``stream: true`` answers in newline-delimited JSON:
  ``message.content`` is the next piece of text, ``message.thinking`` the reasoning
  trace (not shown here). The last object has ``done: true``, ``done_reason``,
  ``prompt_eval_count`` and ``eval_count``. An error after the stream started
  arrives as ``{"error": "..."}``; before it, as an HTTP status (400, 404 for an
  unknown model, 429, 500, 502) with an ``{"error": "..."}`` body.
* Messages have ``role`` (system, user, assistant), ``content`` and, for models with
  the ``vision`` capability, ``images`` (base64).
* ``options.num_predict`` limits the output length; ``options.temperature``.
* ``think: false`` asks for no reasoning output (models that cannot turn it off use
  their lowest level), which keeps replies quick on a laptop.
* No API key. Ollama listens on http://localhost:11434 by default. Models can be
  added at any time (``ollama pull``), so the list is refreshed while running.
"""

import asyncio
import base64
import json
import logging
import time
from collections.abc import AsyncIterator
from typing import Any

import httpx2

from app.ai_providers.base import (
    AIProvider,
    CapabilityNotSupportedError,
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

DEFAULT_BASE_URL = "http://localhost:11434"
# How often the installed models are checked again (on use, not in the background).
REFRESH_INTERVAL_SECONDS = 15.0
CHAT_CAPABILITIES = ProviderCapabilities(text_streaming=True)
VISION_CHAT_CAPABILITIES = ProviderCapabilities(text_streaming=True, image_input=True)


def _error_event(code: str, message: str) -> ChatStreamEvent:
    return ChatStreamEvent(type="error", error_code=code, error_message=message)


def _ollama_error_text(body: bytes) -> str:
    try:
        data = json.loads(body)
    except ValueError:
        return body[:300].decode("utf-8", "replace")
    if isinstance(data, dict) and isinstance(data.get("error"), str):
        return data["error"]
    return str(data)[:300]


def map_status_error(status: int, detail: str) -> ChatStreamEvent:
    """An HTTP error before the stream started -> a provider-neutral error event."""
    logger.error("Ollama returned HTTP %s: %s", status, detail)
    if status == 404:
        return _error_event("provider_model_unavailable", "The selected model is not installed in Ollama.")
    if status == 429:
        return _error_event("provider_rate_limited", "Ollama is busy. Try again shortly.")
    if 400 <= status < 500:
        return _error_event("provider_bad_request", "Ollama could not process this request.")
    return _error_event("provider_unavailable", "Ollama returned an error. Try again shortly.")


def _matches(wanted: str, installed: str) -> bool:
    """``gemma4`` means ``gemma4:latest``, as in the ollama CLI."""
    return installed == wanted or (":" not in wanted and installed == f"{wanted}:latest")


def _display_name(name: str) -> str:
    return name.removesuffix(":latest")


class OllamaProvider(AIProvider):
    id = "ollama"
    display_name = "Ollama (this computer)"

    def __init__(
        self,
        *,
        base_url: str = DEFAULT_BASE_URL,
        allowed_models: list[str] | None = None,
        default_model: str | None = None,
        timeout_seconds: float = 120,
        http_client: httpx2.AsyncClient | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._allowed = list(dict.fromkeys(allowed_models or []))
        self._preferred_default = default_model
        self._owns_client = http_client is None
        # A short connect timeout: Ollama is local, so "not running" shows at once.
        self._client = http_client or httpx2.AsyncClient(timeout=httpx2.Timeout(timeout_seconds, connect=5.0))
        self._models: list[ModelInfo] = []
        self._capabilities: dict[str, set[str]] = {}  # by model digest
        self._last_refresh = float("-inf")
        self._refresh_lock = asyncio.Lock()
        self._reachable: bool | None = None

    @classmethod
    def from_settings(cls, settings: Settings) -> "OllamaProvider":
        assert settings.ollama_base_url is not None
        return cls(
            base_url=settings.ollama_base_url,
            allowed_models=settings.ollama_allowed_models,
            default_model=settings.ollama_default_model,
            timeout_seconds=settings.ai_request_timeout_seconds,
        )

    # ------------------------------------------------------------------ catalog

    def list_models(self) -> list[ModelInfo]:
        return list(self._models)

    async def refresh(self, *, force: bool = False) -> None:
        if not force and time.monotonic() - self._last_refresh < REFRESH_INTERVAL_SECONDS:
            return
        async with self._refresh_lock:
            if not force and time.monotonic() - self._last_refresh < REFRESH_INTERVAL_SECONDS:
                return
            self._last_refresh = time.monotonic()
            try:
                models = await self._discover()
            except (httpx2.HTTPError, ValueError) as exc:
                # Keep the last known list: a chat then says that Ollama is not running.
                if self._reachable is not False:
                    logger.warning("Ollama is not reachable at %s: %s", self._base_url, exc or type(exc).__name__)
                self._reachable = False
                return
            if self._reachable is not True or [m.id for m in models] != [m.id for m in self._models]:
                if models:
                    logger.info("Ollama models: %s", ", ".join(m.id for m in models))
                else:
                    logger.warning("Ollama has no chat models installed. Install one with: ollama pull <model>")
            self._reachable = True
            self._models = models

    async def _discover(self) -> list[ModelInfo]:
        response = await self._client.get(f"{self._base_url}/api/tags", timeout=5.0)
        response.raise_for_status()
        installed: dict[str, str] = {}
        for entry in response.json().get("models") or []:
            name = entry.get("name") or entry.get("model")
            if isinstance(name, str) and name:
                installed[name] = str(entry.get("digest") or name)

        if self._allowed:
            names = [n for wanted in self._allowed for n in installed if _matches(wanted, n)]
        else:
            names = list(installed)
        chat_models: list[tuple[str, bool]] = []
        for name in dict.fromkeys(names):
            capabilities = await self._model_capabilities(name, installed[name])
            if "completion" in capabilities:  # embedding-only models cannot chat
                chat_models.append((name, "vision" in capabilities))

        default = next(
            (n for n, _ in chat_models if self._preferred_default and _matches(self._preferred_default, n)),
            chat_models[0][0] if chat_models else None,
        )
        return [
            ModelInfo(
                id=name,
                display_name=_display_name(name),
                capabilities=VISION_CHAT_CAPABILITIES if vision else CHAT_CAPABILITIES,
                is_default=name == default,
            )
            for name, vision in chat_models
        ]

    async def _model_capabilities(self, name: str, digest: str) -> set[str]:
        cached = self._capabilities.get(digest)
        if cached is not None:
            return cached
        response = await self._client.post(f"{self._base_url}/api/show", json={"model": name}, timeout=10.0)
        response.raise_for_status()
        capabilities = {str(c) for c in response.json().get("capabilities") or []}
        # Servers that do not report capabilities: assume a text chat model.
        capabilities = capabilities or {"completion"}
        self._capabilities[digest] = capabilities
        return capabilities

    # ------------------------------------------------------------------ text chat

    def build_payload(self, request: ChatRequest) -> dict[str, Any]:
        model = self.get_model(request.model)
        vision = bool(model and model.capabilities.image_input)
        messages: list[dict[str, Any]] = []
        for turn in request.turns:
            message: dict[str, Any] = {"role": turn.role, "content": turn.content}
            images = [base64.b64encode(a.data).decode("ascii") for a in turn.attachments if a.kind == "image"]
            if images and vision:
                message["images"] = images
            messages.append(message)
        payload: dict[str, Any] = {"model": request.model, "messages": messages, "stream": True, "think": False}
        options: dict[str, Any] = {}
        if request.max_output_tokens is not None:
            options["num_predict"] = request.max_output_tokens
        if request.temperature is not None:
            options["temperature"] = request.temperature
        if options:
            payload["options"] = options
        return payload

    async def stream_chat(self, request: ChatRequest) -> AsyncIterator[ChatStreamEvent]:
        payload = self.build_payload(request)
        try:
            async with self._client.stream("POST", f"{self._base_url}/api/chat", json=payload) as response:
                if response.status_code >= 400:
                    yield map_status_error(response.status_code, _ollama_error_text(await response.aread()))
                    return
                async for line in response.aiter_lines():
                    if not line.strip():
                        continue
                    try:
                        chunk = json.loads(line)
                    except ValueError:
                        logger.error("Ollama sent a line that is not JSON: %.200s", line)
                        yield _error_event("provider_failed", "The local model sent an unreadable response.")
                        return
                    if chunk.get("error"):
                        logger.error("Ollama failed while generating: %s", chunk["error"])
                        yield _error_event("provider_failed", "The local model stopped with an error.")
                        return
                    text = (chunk.get("message") or {}).get("content")
                    if text:
                        yield ChatStreamEvent(type="text_delta", text=text)
                    if chunk.get("done"):
                        for event in self._finish(chunk):
                            yield event
                        return
        except httpx2.ConnectError as exc:
            logger.warning("Could not connect to Ollama at %s: %s", self._base_url, exc)
            yield _error_event(
                "provider_unavailable", "Ollama is not running on this computer. Start Ollama and try again."
            )
            return
        except httpx2.TimeoutException:
            yield _error_event("provider_timeout", "The local model took too long to respond.")
            return
        except httpx2.HTTPError as exc:
            logger.warning("Ollama connection failed: %s", exc)
            yield _error_event("provider_unavailable", "The connection to Ollama was lost.")
            return
        yield _error_event("provider_stream_interrupted", "The local model closed the stream unexpectedly.")

    @staticmethod
    def _finish(chunk: dict[str, Any]) -> list[ChatStreamEvent]:
        metadata: dict[str, Any] = {}
        if chunk.get("model"):
            metadata["model_version"] = chunk["model"]
        reason = chunk.get("done_reason") or "stop"
        if reason == "length":
            metadata["incomplete_reason"] = "max_output_tokens"
        elif reason != "stop":
            metadata["incomplete_reason"] = str(reason)
        events: list[ChatStreamEvent] = []
        input_tokens, output_tokens = chunk.get("prompt_eval_count"), chunk.get("eval_count")
        if isinstance(input_tokens, int) or isinstance(output_tokens, int):
            total = (input_tokens or 0) + (output_tokens or 0)
            usage = ChatUsage(input_tokens=input_tokens, output_tokens=output_tokens, total_tokens=total)
            events.append(ChatStreamEvent(type="usage", usage=usage))
        events.append(ChatStreamEvent(type="done", provider_metadata=metadata))
        return events

    # ------------------------------------------------------------------ realtime voice

    async def create_realtime_session(self, request: RealtimeSessionRequest) -> RealtimeSessionDescriptor:
        raise CapabilityNotSupportedError(self.id, "realtime voice")

    async def aclose(self) -> None:
        if self._owns_client:
            await self._client.aclose()

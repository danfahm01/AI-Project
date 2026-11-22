"""Ollama adapter against a mocked HTTP transport speaking the documented Ollama
API (docs.ollama.com: /api/tags, /api/show, /api/chat with NDJSON streaming)."""

import base64
import json
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any

import httpx2
import pytest
from fastapi import FastAPI
from httpx import AsyncClient

from app.ai_providers import ollama_provider
from app.ai_providers.base import (
    CapabilityNotSupportedError,
    ChatAttachment,
    ChatRequest,
    ChatStreamEvent,
    ChatTurn,
    RealtimeSessionRequest,
)
from app.ai_providers.ollama_provider import OllamaProvider
from app.ai_providers.registry import ProviderRegistry, build_provider_registry
from tests.conftest import make_settings
from tests.test_chat_socket import TERMINAL, Harness, authed, make_harness, read_until, send

BASE = "http://ollama.test:11434"
API = "/api/v1"

TAGS = {
    "models": [
        {"name": "gemma4:e4b", "model": "gemma4:e4b", "digest": "d-gemma", "size": 6_600_000_000},
        {"name": "qwen3:latest", "model": "qwen3:latest", "digest": "d-qwen", "size": 5_200_000_000},
        {"name": "nomic-embed-text:latest", "model": "nomic-embed-text:latest", "digest": "d-embed"},
    ]
}
CAPABILITIES = {
    "gemma4:e4b": ["completion", "vision", "thinking", "tools"],
    "qwen3:latest": ["completion", "thinking", "tools"],
    "nomic-embed-text:latest": ["embedding"],
}


def ndjson(*objects: dict[str, Any], status: int = 200) -> httpx2.Response:
    body = "".join(json.dumps(o) + "\n" for o in objects)
    return httpx2.Response(status, headers={"content-type": "application/x-ndjson"}, text=body)


def delta(text: str) -> dict[str, Any]:
    return {"model": "gemma4:e4b", "message": {"role": "assistant", "content": text}, "done": False}


def final(reason: str = "stop", **extra: Any) -> dict[str, Any]:
    return {
        "model": "gemma4:e4b",
        "message": {"role": "assistant", "content": ""},
        "done": True,
        "done_reason": reason,
        "prompt_eval_count": 21,
        "eval_count": 4,
        **extra,
    }


class FakeOllama:
    """Answers like an Ollama server; records what it was sent."""

    def __init__(self, chat: Callable[[dict[str, Any]], httpx2.Response] | None = None) -> None:
        self.chat = chat or (lambda _: ndjson(delta("Halo"), delta(", apa kabar?"), final()))
        self.tags = TAGS
        self.requests: list[tuple[str, dict[str, Any] | None]] = []
        self.down = False

    def __call__(self, request: httpx2.Request) -> httpx2.Response:
        if self.down:
            raise httpx2.ConnectError("connection refused", request=request)
        body = json.loads(request.content) if request.content else None
        self.requests.append((request.url.path, body))
        assert str(request.url).startswith(BASE)
        if request.url.path == "/api/tags":
            return httpx2.Response(200, json=self.tags)
        if request.url.path == "/api/show":
            return httpx2.Response(200, json={"capabilities": CAPABILITIES[body["model"]]})
        if request.url.path == "/api/chat":
            return self.chat(body)
        return httpx2.Response(404, json={"error": "not found"})

    def paths(self) -> list[str]:
        return [path for path, _ in self.requests]


def make_provider(fake: FakeOllama, **kwargs: Any) -> OllamaProvider:
    return OllamaProvider(
        base_url=BASE + "/", http_client=httpx2.AsyncClient(transport=httpx2.MockTransport(fake)), **kwargs
    )


def chat_request(*turns: ChatTurn, model: str = "gemma4:e4b", **kwargs: Any) -> ChatRequest:
    return ChatRequest(model=model, turns=list(turns) or [ChatTurn(role="user", content="Halo")], **kwargs)


async def collect(provider: OllamaProvider, request: ChatRequest) -> list[ChatStreamEvent]:
    return [event async for event in provider.stream_chat(request)]


# --------------------------------------------------------------------------- models


async def test_discovers_installed_chat_models() -> None:
    fake = FakeOllama()
    provider = make_provider(fake)
    assert provider.list_models() == []  # nothing known before the first refresh

    await provider.refresh(force=True)

    models = provider.list_models()
    assert [(m.id, m.display_name, m.is_default) for m in models] == [
        ("gemma4:e4b", "gemma4:e4b", True),
        ("qwen3:latest", "qwen3", False),
    ]  # the embedding model cannot chat
    gemma, qwen = models
    assert gemma.capabilities.text_streaming and gemma.capabilities.image_input
    assert not gemma.capabilities.pdf_input and not gemma.capabilities.realtime_voice
    assert qwen.capabilities.text_streaming and not qwen.capabilities.image_input
    assert fake.paths() == ["/api/tags", "/api/show", "/api/show", "/api/show"]


async def test_allowed_models_and_default() -> None:
    provider = make_provider(
        FakeOllama(), allowed_models=["qwen3", "gemma4:e4b", "missing"], default_model="gemma4:e4b"
    )
    await provider.refresh(force=True)
    assert [(m.id, m.is_default) for m in provider.list_models()] == [("qwen3:latest", False), ("gemma4:e4b", True)]


async def test_refresh_is_rate_limited_and_capabilities_are_cached(monkeypatch: pytest.MonkeyPatch) -> None:
    clock = [1000.0]
    monkeypatch.setattr(ollama_provider.time, "monotonic", lambda: clock[0])
    fake = FakeOllama()
    provider = make_provider(fake)
    await provider.refresh()
    await provider.refresh()  # within the interval: no request
    assert fake.paths().count("/api/tags") == 1

    clock[0] += ollama_provider.REFRESH_INTERVAL_SECONDS + 1
    fake.tags = {"models": [*TAGS["models"], {"name": "gemma4:e2b", "digest": "d-e2b"}]}
    CAPABILITIES["gemma4:e2b"] = ["completion", "vision"]
    try:
        await provider.refresh()
    finally:
        del CAPABILITIES["gemma4:e2b"]
    assert "gemma4:e2b" in [m.id for m in provider.list_models()]
    # Known digests are not asked again: only the new model.
    shown = [body["model"] for path, body in fake.requests if path == "/api/show"]
    assert shown == ["gemma4:e4b", "qwen3:latest", "nomic-embed-text:latest", "gemma4:e2b"]


async def test_unreachable_ollama_keeps_the_last_known_models(caplog: pytest.LogCaptureFixture) -> None:
    fake = FakeOllama()
    provider = make_provider(fake)
    await provider.refresh(force=True)
    fake.down = True
    await provider.refresh(force=True)
    await provider.refresh(force=True)
    assert [m.id for m in provider.list_models()] == ["gemma4:e4b", "qwen3:latest"]
    assert sum("not reachable" in r.message for r in caplog.records) == 1  # logged once, not per request


async def test_never_reached_means_no_models() -> None:
    fake = FakeOllama()
    fake.down = True
    provider = make_provider(fake)
    await provider.refresh(force=True)
    assert provider.list_models() == []


# --------------------------------------------------------------------------- chat


async def test_streams_text_usage_and_done() -> None:
    fake = FakeOllama()
    provider = make_provider(fake)
    await provider.refresh(force=True)

    events = await collect(
        provider,
        chat_request(
            ChatTurn(role="system", content="Be brief."),
            ChatTurn(role="user", content="Halo"),
            max_output_tokens=256,
            temperature=0.3,
        ),
    )

    assert [(e.type, e.text) for e in events if e.type == "text_delta"] == [
        ("text_delta", "Halo"),
        ("text_delta", ", apa kabar?"),
    ]
    usage = next(e.usage for e in events if e.type == "usage")
    assert (usage.input_tokens, usage.output_tokens, usage.total_tokens) == (21, 4, 25)
    assert events[-1].type == "done"
    assert events[-1].provider_metadata == {"model_version": "gemma4:e4b"}

    path, body = fake.requests[-1]
    assert path == "/api/chat"
    assert body == {
        "model": "gemma4:e4b",
        "messages": [{"role": "system", "content": "Be brief."}, {"role": "user", "content": "Halo"}],
        "stream": True,
        "think": False,
        "options": {"num_predict": 256, "temperature": 0.3},
    }


async def test_images_go_only_to_vision_models() -> None:
    fake = FakeOllama()
    provider = make_provider(fake)
    await provider.refresh(force=True)
    picture = ChatAttachment(kind="image", mime_type="image/png", filename="a.png", data=b"\x89PNG-bytes")
    turn = ChatTurn(role="user", content="What is this?", attachments=[picture])

    await collect(provider, chat_request(turn, model="gemma4:e4b"))
    assert fake.requests[-1][1]["messages"][0]["images"] == [base64.b64encode(b"\x89PNG-bytes").decode()]

    await collect(provider, chat_request(turn, model="qwen3:latest"))
    assert "images" not in fake.requests[-1][1]["messages"][0]
    assert "options" not in fake.requests[-1][1]


async def test_length_limit_is_reported_as_incomplete() -> None:
    provider = make_provider(FakeOllama(lambda _: ndjson(delta("Cut"), final("length"))))
    events = await collect(provider, chat_request())
    assert events[-1].type == "done"
    assert events[-1].provider_metadata["incomplete_reason"] == "max_output_tokens"


@pytest.mark.parametrize(
    ("status", "code"),
    [
        (404, "provider_model_unavailable"),
        (400, "provider_bad_request"),
        (429, "provider_rate_limited"),
        (500, "provider_unavailable"),
        (502, "provider_unavailable"),
    ],
)
async def test_http_errors_before_the_stream(status: int, code: str) -> None:
    response = httpx2.Response(status, json={"error": "model 'x' not found"})
    events = await collect(make_provider(FakeOllama(lambda _: response)), chat_request())
    assert [(e.type, e.error_code) for e in events] == [("error", code)]
    assert "not found" not in (events[0].error_message or "")  # raw text is only logged


async def test_error_while_streaming_keeps_partial_text() -> None:
    chat = lambda _: ndjson(delta("Half "), {"error": "an error was encountered while running the model"})  # noqa: E731
    events = await collect(make_provider(FakeOllama(chat)), chat_request())
    assert [(e.type, e.text or e.error_code) for e in events] == [
        ("text_delta", "Half "),
        ("error", "provider_failed"),
    ]


async def test_stream_without_done_is_interrupted() -> None:
    events = await collect(make_provider(FakeOllama(lambda _: ndjson(delta("Hi")))), chat_request())
    assert events[-1].error_code == "provider_stream_interrupted"


async def test_unreadable_line_fails() -> None:
    bad = lambda _: httpx2.Response(200, text="not json\n")  # noqa: E731
    events = await collect(make_provider(FakeOllama(bad)), chat_request())
    assert events[-1].error_code == "provider_failed"


async def test_ollama_not_running() -> None:
    fake = FakeOllama()
    fake.down = True
    events = await collect(make_provider(fake), chat_request())
    assert [(e.type, e.error_code) for e in events] == [("error", "provider_unavailable")]
    assert "Ollama is not running" in (events[0].error_message or "")


async def test_timeout() -> None:
    def slow(request: httpx2.Request) -> httpx2.Response:
        raise httpx2.ReadTimeout("slow", request=request)

    provider = OllamaProvider(base_url=BASE, http_client=httpx2.AsyncClient(transport=httpx2.MockTransport(slow)))
    events = await collect(provider, chat_request())
    assert [(e.type, e.error_code) for e in events] == [("error", "provider_timeout")]


async def test_no_voice() -> None:
    with pytest.raises(CapabilityNotSupportedError):
        await make_provider(FakeOllama()).create_realtime_session(RealtimeSessionRequest(model="gemma4:e4b"))


async def test_own_http_client_is_closed() -> None:
    provider = OllamaProvider(base_url=BASE)
    await provider.aclose()
    assert provider._client.is_closed


# --------------------------------------------------------------------------- app


def test_registry_from_settings(tmp_path: Path) -> None:
    registry = build_provider_registry(
        make_settings(
            tmp_path,
            ollama_base_url="http://localhost:11434",
            ollama_allowed_models="gemma4:e4b, qwen3",
            ollama_default_model="qwen3",
        )
    )
    [provider] = registry.list()
    assert isinstance(provider, OllamaProvider)
    assert provider._allowed == ["gemma4:e4b", "qwen3"]
    assert provider._preferred_default == "qwen3"
    assert provider._base_url == "http://localhost:11434"


async def test_providers_endpoint_lists_ollama_only_with_models(
    app: FastAPI, client: AsyncClient, auth_headers: dict[str, str]
) -> None:
    fake = FakeOllama()
    fake.down = True
    app.state.providers = ProviderRegistry([make_provider(fake)])

    empty = (await client.get(f"{API}/providers", headers=auth_headers)).json()
    assert empty == {"items": [], "default_provider": None}

    fake.down = False
    provider = app.state.providers.get("ollama")
    provider._last_refresh = float("-inf")  # Ollama started: the next request checks again
    listed = (await client.get(f"{API}/providers", headers=auth_headers)).json()
    assert listed["default_provider"] == "ollama"
    [ollama] = listed["items"]
    assert ollama["display_name"] == "Ollama (this computer)"
    assert [m["id"] for m in ollama["models"]] == ["gemma4:e4b", "qwen3:latest"]
    assert ollama["models"][0]["capabilities"]["image_input"] is True


@pytest.fixture
def harness(tmp_path: Path) -> Iterator[Harness]:
    yield from make_harness(tmp_path)


def test_chat_with_ollama_end_to_end(harness: Harness) -> None:
    fake = FakeOllama(lambda _: ndjson(delta("Halo! "), delta("Saya model lokal."), final()))
    harness.app.state.providers = ProviderRegistry([make_provider(fake)])
    token = harness.register()
    conversation_id = harness.new_conversation(token)

    with harness.client.websocket_connect("/api/v1/chat/ws") as ws:
        authed(ws, token)
        send(ws, conversation_id, "Halo, siapa kamu?")
        events = read_until(ws, *TERMINAL)

    assert events[-1]["type"] == "response.completed", events[-1]
    reply = events[-1]["message"]
    assert reply["content"] == "Halo! Saya model lokal."
    assert (reply["provider"], reply["model"]) == ("ollama", "gemma4:e4b")
    assert reply["usage"]["output_tokens"] == 4
    # The chat refreshed the model list itself (no /providers call was made first).
    sent = [body for path, body in fake.requests if path == "/api/chat"]
    assert sent[0]["messages"][-1] == {"role": "user", "content": "Halo, siapa kamu?"}
    assert sent[0]["messages"][0]["role"] == "system"

"""Claude adapter against a mocked HTTP transport speaking the documented
Messages API streaming format (no network, no credits)."""

import json
from collections.abc import Callable, Iterator
from pathlib import Path
from typing import Any

import httpx2
import pytest

from app.ai_providers.anthropic_provider import AnthropicProvider
from app.ai_providers.base import (
    CapabilityNotSupportedError,
    ChatAttachment,
    ChatRequest,
    ChatStreamEvent,
    ChatTurn,
    RealtimeSessionRequest,
)
from app.ai_providers.registry import ProviderRegistry, build_provider_registry
from tests.conftest import make_settings
from tests.test_chat_socket import TERMINAL, Harness, authed, make_harness, read_until, send

Handler = Callable[[httpx2.Request], httpx2.Response]


def sse(*events: dict[str, Any]) -> httpx2.Response:
    body = "".join(f"event: {e['type']}\ndata: {json.dumps(e)}\n\n" for e in events)
    return httpx2.Response(200, headers={"content-type": "text/event-stream"}, text=body)


def message_start(model: str = "claude-opus-5-5") -> dict[str, Any]:
    usage = {"input_tokens": 12, "output_tokens": 1, "cache_creation_input_tokens": 3, "cache_read_input_tokens": 5}
    message = {
        "id": "msg_1",
        "type": "message",
        "role": "assistant",
        "model": model,
        "content": [],
        "stop_reason": None,
        "stop_sequence": None,
        "usage": usage,
    }
    return {"type": "message_start", "message": message}


def thinking_block(index: int) -> list[dict[str, Any]]:
    """Adaptive thinking with the default display ("omitted"): no visible text."""
    return [
        {
            "type": "content_block_start",
            "index": index,
            "content_block": {"type": "thinking", "thinking": "", "signature": ""},
        },
        {"type": "content_block_delta", "index": index, "delta": {"type": "signature_delta", "signature": "sig"}},
        {"type": "content_block_stop", "index": index},
    ]


def text_block(index: int, *chunks: str) -> list[dict[str, Any]]:
    return [
        {"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}},
        *({"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": c}} for c in chunks),
        {"type": "content_block_stop", "index": index},
    ]


def finish(stop_reason: str = "end_turn", output_tokens: int = 7, **extra: Any) -> list[dict[str, Any]]:
    delta = {"stop_reason": stop_reason, "stop_sequence": None, **extra}
    return [
        {"type": "message_delta", "delta": delta, "usage": {"output_tokens": output_tokens}},
        {"type": "message_stop"},
    ]


def reply(*chunks: str, stop_reason: str = "end_turn", **extra: Any) -> Handler:
    events = [message_start(), *thinking_block(0)]
    if chunks:
        events += text_block(1, *chunks)
    events += finish(stop_reason, **extra)
    return lambda _: sse(*events)


def make_provider(handler: Handler, **kwargs: Any) -> AnthropicProvider:
    return AnthropicProvider(
        api_key="sk-ant-server-key",
        models=["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
        default_model="claude-opus-5-5",
        http_client=httpx2.AsyncClient(transport=httpx2.MockTransport(handler)),
        max_retries=0,
        **kwargs,
    )


REQUEST = ChatRequest(
    model="claude-opus-5-5",
    turns=[
        ChatTurn(role="system", content="Be brief."),
        ChatTurn(role="user", content="Hi"),
        ChatTurn(role="assistant", content="Hello!"),
        ChatTurn(role="user", content="Say thanks"),
    ],
    temperature=0.3,
    end_user_id="hashed-user",
)


async def collect(provider: AnthropicProvider, request: ChatRequest = REQUEST) -> list[ChatStreamEvent]:
    return [event async for event in provider.stream_chat(request)]


# --------------------------------------------------------------------------- text chat


async def test_streams_text_usage_and_done_with_documented_request_shape() -> None:
    seen: list[httpx2.Request] = []

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen.append(request)
        return reply("Thank", "s!")(request)

    events = await collect(make_provider(handler))

    assert [e.type for e in events] == ["text_delta", "text_delta", "usage", "done"]
    assert "".join(e.text or "" for e in events) == "Thanks!"
    usage = events[2].usage
    assert usage is not None
    # Cached prompt tokens count as input too.
    assert (usage.input_tokens, usage.output_tokens, usage.total_tokens) == (20, 7, 27)
    assert events[3].provider_metadata == {"response_id": "msg_1", "model_version": "claude-opus-5-5"}

    [request] = seen
    assert request.method == "POST"
    assert request.url.path == "/v1/messages"
    # SDK 2.x sends the API key as a bearer token (older releases used x-api-key).
    assert request.headers.get("authorization") == "Bearer sk-ant-server-key"
    assert "server-side-fallback-2026-07-01" in request.headers["anthropic-beta"]
    body = json.loads(request.content)
    assert body["model"] == "claude-opus-5-5"
    assert body["stream"] is True
    assert body["max_tokens"] == 64_000
    assert body["system"] == "Be brief."
    assert body["messages"] == [
        {"role": "user", "content": "Hi"},
        {"role": "assistant", "content": "Hello!"},
        {"role": "user", "content": "Say thanks"},
    ]
    assert body["metadata"] == {"user_id": "hashed-user"}
    assert body["fallbacks"] == "default"
    assert body["cache_control"] == {"type": "ephemeral"}
    # Sampling parameters are rejected by the API and never sent.
    assert "temperature" not in body
    # Thinking stays at the model's default (adaptive).
    assert "thinking" not in body


async def test_models_without_server_side_fallback_skip_the_beta() -> None:
    seen: list[httpx2.Request] = []

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen.append(request)
        return reply("Hi")(request)

    await collect(make_provider(handler), REQUEST.model_copy(update={"model": "claude-haiku-5-5"}))
    body = json.loads(seen[0].content)
    assert "fallbacks" not in body
    assert "server-side-fallback" not in seen[0].headers.get("anthropic-beta", "")


async def test_images_and_pdfs_go_before_the_text_and_history_starts_with_the_user() -> None:
    seen: list[httpx2.Request] = []

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen.append(request)
        return reply("Ok")(request)

    request = ChatRequest(
        model="claude-sonnet-5-5",
        max_output_tokens=500,
        turns=[
            ChatTurn(role="assistant", content="Earlier reply cut off by the history budget"),
            ChatTurn(role="user", content=""),
            ChatTurn(
                role="user",
                content="What is this?",
                attachments=[
                    ChatAttachment(kind="image", mime_type="image/png", filename="a.png", data=b"png"),
                    ChatAttachment(kind="pdf", mime_type="application/pdf", filename="b.pdf", data=b"%PDF"),
                ],
            ),
        ],
    )
    await collect(make_provider(handler), request)
    body = json.loads(seen[0].content)
    assert body["max_tokens"] == 500
    assert "system" not in body and "metadata" not in body
    assert body["messages"] == [
        {
            "role": "user",
            "content": [
                {"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "cG5n"}},
                {"type": "document", "source": {"type": "base64", "media_type": "application/pdf", "data": "JVBERg=="}},
                {"type": "text", "text": "What is this?"},
            ],
        }
    ]


async def test_max_tokens_keeps_partial_text() -> None:
    events = await collect(make_provider(reply("Partial", stop_reason="max_tokens")))
    assert events[-1].type == "done"
    assert events[-1].provider_metadata is not None
    assert events[-1].provider_metadata["incomplete_reason"] == "max_output_tokens"


async def test_refusal_keeps_text_or_reports_a_block() -> None:
    events = await collect(make_provider(reply("Some", stop_reason="refusal")))
    assert events[-1].provider_metadata is not None
    assert events[-1].provider_metadata["incomplete_reason"] == "content_filter"

    events = await collect(make_provider(reply(stop_reason="refusal")))
    assert [e.type for e in events] == ["error"]
    assert events[0].error_code == "provider_content_blocked"


async def test_stream_that_ends_without_a_stop_reason() -> None:
    events = [message_start(), *text_block(0, "Hel")]
    result = await collect(make_provider(lambda _: sse(*events)))
    assert result[-1].type == "error"
    assert result[-1].error_code == "provider_stream_interrupted"


async def test_error_event_in_the_middle_of_the_stream() -> None:
    error = {"type": "error", "error": {"type": "overloaded_error", "message": "secret account detail"}}
    events = [message_start(), *text_block(0, "Hel"), error]
    result = await collect(make_provider(lambda _: sse(*events)))
    assert result[0].type == "text_delta"
    assert result[-1].type == "error"
    assert result[-1].error_code == "provider_rate_limited"
    assert "secret account detail" not in (result[-1].error_message or "")


@pytest.mark.parametrize(
    ("status", "error_type", "message", "expected_code"),
    [
        (401, "authentication_error", "secret account detail", "provider_auth_failed"),
        (403, "permission_error", "secret account detail", "provider_auth_failed"),
        (404, "not_found_error", "secret account detail", "provider_model_unavailable"),
        (400, "invalid_request_error", "secret account detail", "provider_bad_request"),
        (400, "invalid_request_error", "Your credit balance is too low to access the API.", "provider_out_of_credit"),
        (402, "billing_error", "secret account detail", "provider_out_of_credit"),
        (429, "rate_limit_error", "secret account detail", "provider_rate_limited"),
        (529, "overloaded_error", "secret account detail", "provider_rate_limited"),
        (500, "api_error", "secret account detail", "provider_unavailable"),
        (504, "timeout_error", "secret account detail", "provider_timeout"),
    ],
)
async def test_http_errors_map_to_safe_codes(status: int, error_type: str, message: str, expected_code: str) -> None:
    def handler(_: httpx2.Request) -> httpx2.Response:
        return httpx2.Response(status, json={"type": "error", "error": {"type": error_type, "message": message}})

    events = await collect(make_provider(handler))
    assert [e.type for e in events] == ["error"]
    assert events[0].error_code == expected_code
    assert "secret account detail" not in (events[0].error_message or "")


async def test_network_failures_map_to_unavailable_and_timeout() -> None:
    def refused(request: httpx2.Request) -> httpx2.Response:
        raise httpx2.ConnectError("connection refused", request=request)

    def slow(request: httpx2.Request) -> httpx2.Response:
        raise httpx2.ReadTimeout("timed out", request=request)

    assert (await collect(make_provider(refused)))[0].error_code == "provider_unavailable"
    assert (await collect(make_provider(slow)))[0].error_code == "provider_timeout"


# --------------------------------------------------------------------------- catalog and registry


def test_models_are_listed_with_names_default_and_file_input() -> None:
    models = make_provider(lambda _: httpx2.Response(200)).list_models()
    assert [(m.id, m.display_name, m.is_default) for m in models] == [
        ("claude-opus-5-5", "Claude Opus 5.5", True),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5", False),
        ("claude-haiku-5-5", "Claude Haiku 5.5", False),
    ]
    for model in models:
        caps = model.capabilities
        assert caps.text_streaming and caps.image_input and caps.pdf_input
        assert not caps.realtime_voice


async def test_no_realtime_voice() -> None:
    with pytest.raises(CapabilityNotSupportedError):
        await make_provider(lambda _: httpx2.Response(200)).create_realtime_session(
            RealtimeSessionRequest(model="claude-opus-5-5")
        )


def test_registry_enables_claude_with_a_key(tmp_path: Path) -> None:
    registry = build_provider_registry(
        make_settings(tmp_path, anthropic_api_key="sk-ant-test", anthropic_models="claude-sonnet-5-5, claude-opus-5-5")
    )
    [provider] = registry.list()
    assert provider.id == "anthropic"
    # The configured default is kept when it is in the list.
    assert provider.default_model() is not None
    assert provider.default_model().id == "claude-opus-5-5"  # type: ignore[union-attr]

    together = build_provider_registry(
        make_settings(
            tmp_path, gemini_api_key="g-test", anthropic_api_key="sk-ant-test", default_ai_provider="anthropic"
        )
    )
    assert [p.id for p in together.list()] == ["gemini", "anthropic"]
    assert together.default_id == "anthropic"

    assert not build_provider_registry(make_settings(tmp_path, anthropic_api_key="  ")).list()


def test_production_requires_https_for_anthropic_base_url(tmp_path: Path) -> None:
    with pytest.raises(ValueError, match="ANTHROPIC_BASE_URL"):
        make_settings(
            tmp_path,
            app_env="production",
            jwt_secret="x" * 64,
            cors_origins="https://app.example.com",
            cors_allow_localhost=False,
            anthropic_base_url="http://claude.test",
        )


# --------------------------------------------------------------------------- through the chat socket


@pytest.fixture
def harness(tmp_path: Path) -> Iterator[Harness]:
    yield from make_harness(tmp_path)


def test_chat_with_claude_end_to_end(harness: Harness) -> None:
    seen: list[dict[str, Any]] = []

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen.append(json.loads(request.content))
        return reply("Halo! ", "Saya Claude.")(request)

    harness.app.state.providers = ProviderRegistry([make_provider(handler)])
    token = harness.register()
    conversation_id = harness.new_conversation(token)

    with harness.client.websocket_connect("/api/v1/chat/ws") as ws:
        authed(ws, token)
        send(ws, conversation_id, "Halo, siapa kamu?")
        events = read_until(ws, *TERMINAL)

    assert events[-1]["type"] == "response.completed", events[-1]
    message = events[-1]["message"]
    assert message["content"] == "Halo! Saya Claude."
    assert (message["provider"], message["model"]) == ("anthropic", "claude-opus-5-5")
    assert message["usage"]["output_tokens"] == 7
    assert seen[0]["messages"][-1] == {"role": "user", "content": "Halo, siapa kamu?"}
    assert "LaTeX" in seen[0]["system"]  # the chat system prompt

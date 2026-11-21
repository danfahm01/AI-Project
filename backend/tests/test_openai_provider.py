"""OpenAI adapter against a mocked HTTP transport speaking the documented
Responses API streaming format (no network, no credits)."""

import json
from collections.abc import Callable
from pathlib import Path
from typing import Any

import httpx2
import pytest

from app.ai_providers.base import ChatRequest, ChatStreamEvent, ChatTurn
from app.ai_providers.openai_provider import OpenAIProvider
from app.ai_providers.registry import build_provider_registry
from tests.conftest import make_settings

Handler = Callable[[httpx2.Request], httpx2.Response]


def sse(*events: dict[str, Any]) -> bytes:
    lines = []
    for event in events:
        lines.append(f"event: {event['type']}\ndata: {json.dumps(event)}\n\n")
    return "".join(lines).encode()


def delta(text: str, seq: int) -> dict[str, Any]:
    return {
        "type": "response.output_text.delta",
        "sequence_number": seq,
        "item_id": "msg_1",
        "output_index": 0,
        "content_index": 0,
        "delta": text,
        "logprobs": [],
    }


def finished(kind: str, seq: int, **response: Any) -> dict[str, Any]:
    body = {
        "id": "resp_123",
        "object": "response",
        "created_at": 1,
        "model": "gpt-6-luna",
        "status": "completed" if kind == "response.completed" else "incomplete",
        "output": [],
        "usage": {
            "input_tokens": 12,
            "output_tokens": 3,
            "total_tokens": 15,
            "input_tokens_details": {"cached_tokens": 0},
            "output_tokens_details": {"reasoning_tokens": 0},
        },
        **response,
    }
    return {"type": kind, "sequence_number": seq, "response": body}


def stream_response(body: bytes) -> httpx2.Response:
    return httpx2.Response(200, headers={"content-type": "text/event-stream"}, content=body)


def make_provider(handler: Handler) -> OpenAIProvider:
    return OpenAIProvider(
        api_key="sk-test",
        models=["gpt-6.2-astra", "gpt-6.2-sol", "gpt-6-luna"],
        default_model="gpt-6.2-astra",
        max_retries=0,
        http_client=httpx2.AsyncClient(transport=httpx2.MockTransport(handler)),
    )


REQUEST = ChatRequest(
    model="gpt-6-luna",
    turns=[
        ChatTurn(role="system", content="Be brief."),
        ChatTurn(role="user", content="Hi"),
        ChatTurn(role="assistant", content="Hello!"),
        ChatTurn(role="user", content="Say thanks"),
    ],
    max_output_tokens=256,
    end_user_id="hashed-user",
)


async def collect(provider: OpenAIProvider, request: ChatRequest = REQUEST) -> list[ChatStreamEvent]:
    return [event async for event in provider.stream_chat(request)]


async def test_streams_text_usage_and_done_with_documented_request_shape() -> None:
    seen: list[httpx2.Request] = []

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen.append(request)
        return stream_response(
            sse(
                {
                    "type": "response.created",
                    "sequence_number": 0,
                    "response": {"id": "resp_123", "status": "in_progress"},
                },
                delta("Thank", 1),
                delta("s!", 2),
                {"type": "response.output_text.done", "sequence_number": 3, "text": "Thanks!"},
                finished("response.completed", 4),
            )
        )

    events = await collect(make_provider(handler))

    assert [e.type for e in events] == ["text_delta", "text_delta", "usage", "done"]
    assert "".join(e.text or "" for e in events) == "Thanks!"
    assert events[2].usage is not None
    assert (events[2].usage.input_tokens, events[2].usage.output_tokens, events[2].usage.total_tokens) == (12, 3, 15)
    assert events[3].provider_metadata == {"response_id": "resp_123"}

    [request] = seen
    assert request.method == "POST"
    assert request.url.path.endswith("/responses")
    assert request.headers["authorization"] == "Bearer sk-test"
    body = json.loads(request.content)
    assert body["model"] == "gpt-6-luna"
    assert body["stream"] is True
    assert body["store"] is False  # conversations are stored by us, not by OpenAI
    assert body["instructions"] == "Be brief."
    assert body["input"] == [
        {"role": "user", "content": "Hi"},
        {"role": "assistant", "content": "Hello!"},
        {"role": "user", "content": "Say thanks"},
    ]
    assert body["max_output_tokens"] == 256
    assert body["safety_identifier"] == "hashed-user"


async def test_incomplete_response_keeps_partial_text_and_reason() -> None:
    def handler(_: httpx2.Request) -> httpx2.Response:
        return stream_response(
            sse(
                delta("Partial", 1),
                finished("response.incomplete", 2, incomplete_details={"reason": "max_output_tokens"}),
            )
        )

    events = await collect(make_provider(handler))
    assert events[-1].type == "done"
    assert events[-1].provider_metadata == {"response_id": "resp_123", "incomplete_reason": "max_output_tokens"}


async def test_failed_response_becomes_error_event() -> None:
    def handler(_: httpx2.Request) -> httpx2.Response:
        return stream_response(
            sse(
                delta("Par", 1),
                {
                    "type": "response.failed",
                    "sequence_number": 2,
                    "response": {
                        "id": "resp_123",
                        "status": "failed",
                        "error": {"code": "server_error", "message": "internal details"},
                    },
                },
            )
        )

    events = await collect(make_provider(handler))
    assert [e.type for e in events] == ["text_delta", "error"]
    assert events[-1].error_code == "provider_failed"
    assert "internal details" not in (events[-1].error_message or "")


async def test_error_event_in_stream() -> None:
    def handler(_: httpx2.Request) -> httpx2.Response:
        return stream_response(sse({"type": "error", "sequence_number": 0, "code": "x", "message": "boom"}))

    events = await collect(make_provider(handler))
    assert [e.type for e in events] == ["error"]


async def test_stream_that_ends_without_terminal_event() -> None:
    def handler(_: httpx2.Request) -> httpx2.Response:
        return stream_response(sse(delta("Hel", 1)))

    events = await collect(make_provider(handler))
    assert events[-1].type == "error"
    assert events[-1].error_code == "provider_stream_interrupted"


@pytest.mark.parametrize(
    ("status", "expected_code"),
    [
        (401, "provider_auth_failed"),
        (403, "provider_auth_failed"),
        (404, "provider_model_unavailable"),
        (400, "provider_bad_request"),
        (429, "provider_rate_limited"),
        (500, "provider_unavailable"),
    ],
)
async def test_http_errors_map_to_safe_codes(status: int, expected_code: str) -> None:
    def handler(_: httpx2.Request) -> httpx2.Response:
        return httpx2.Response(status, json={"error": {"message": "secret account detail", "type": "x", "code": None}})

    events = await collect(make_provider(handler))
    assert [e.type for e in events] == ["error"]
    assert events[0].error_code == expected_code
    assert "secret account detail" not in (events[0].error_message or "")


async def test_network_failure_maps_to_unavailable() -> None:
    def handler(request: httpx2.Request) -> httpx2.Response:
        raise httpx2.ConnectError("connection refused", request=request)

    events = await collect(make_provider(handler))
    assert events[0].error_code == "provider_unavailable"


def test_models_are_listed_with_verified_names_and_default() -> None:
    provider = make_provider(lambda _: httpx2.Response(200))
    models = provider.list_models()
    assert [(m.id, m.display_name, m.is_default) for m in models] == [
        ("gpt-6.2-astra", "GPT-6.2 Astra", True),
        ("gpt-6.2-sol", "GPT-6.2 Sol", False),
        ("gpt-6-luna", "GPT-6 Luna", False),
    ]
    assert all(m.capabilities.text_streaming for m in models)
    assert not any(m.capabilities.realtime_voice for m in models)  # phase 3


def test_unknown_configured_model_is_shown_by_id_and_bad_default_falls_back() -> None:
    provider = OpenAIProvider(api_key="sk-test", models=["custom-model"], default_model="missing")
    [model] = provider.list_models()
    assert (model.id, model.display_name, model.is_default) == ("custom-model", "custom-model", True)


def test_registry_enables_openai_only_with_a_key(tmp_path: Path) -> None:
    assert build_provider_registry(make_settings(tmp_path)).list() == []
    registry = build_provider_registry(
        make_settings(tmp_path, openai_api_key="sk-test", openai_models="gpt-6-luna, gpt-6.2-sol")
    )
    [provider] = registry.list()
    assert provider.id == "openai"
    models = provider.list_models()
    assert [m.id for m in models if m.capabilities.text_streaming] == ["gpt-6-luna", "gpt-6.2-sol"]
    # The realtime voice model is listed too (OPENAI_REALTIME_MODEL, on by default).
    assert [m.id for m in models if m.capabilities.realtime_voice] == ["gpt-realtime-2.1"]
    voiceless = build_provider_registry(
        make_settings(tmp_path, openai_api_key="sk-test", openai_realtime_model="")
    ).list()[0]
    assert not any(m.capabilities.realtime_voice for m in voiceless.list_models())

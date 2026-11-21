"""Gemini adapter against a mocked HTTP transport speaking the documented
Gemini API formats (no network, no credits)."""

import json
from collections.abc import Callable
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import httpx2
import pytest
from fastapi import FastAPI
from httpx import AsyncClient

from app.ai_providers.base import (
    CapabilityNotSupportedError,
    ChatRequest,
    ChatStreamEvent,
    ChatTurn,
    ProviderError,
    RealtimeSessionRequest,
)
from app.ai_providers.gemini_provider import GeminiProvider
from app.ai_providers.registry import ProviderRegistry, build_provider_registry
from tests.conftest import make_settings

Handler = Callable[[httpx2.Request], httpx2.Response]
API = "/api/v1"


def sse(*chunks: dict[str, Any]) -> httpx2.Response:
    body = "".join(f"data: {json.dumps(chunk)}\r\n\r\n" for chunk in chunks)
    return httpx2.Response(200, headers={"content-type": "text/event-stream"}, text=body)


def text_chunk(text: str, finish: str | None = None, **extra: Any) -> dict[str, Any]:
    candidate: dict[str, Any] = {"content": {"role": "model", "parts": [{"text": text}]}, "index": 0}
    if finish:
        candidate["finishReason"] = finish
    return {"candidates": [candidate], **extra}


USAGE = {"promptTokenCount": 12, "candidatesTokenCount": 3, "thoughtsTokenCount": 2, "totalTokenCount": 17}


def make_provider(handler: Handler, base_url: str | None = None, **kwargs: Any) -> GeminiProvider:
    return GeminiProvider(
        api_key="server-gemini-key",
        models=["gemini-4-hydrogen", "gemini-4-carbon", "gemini-3.5-flash-lite"],
        default_model="gemini-4-hydrogen",
        base_url=base_url,
        http_client=httpx2.AsyncClient(transport=httpx2.MockTransport(handler)),
        live_model="gemini-3.8-live",
        live_voices=["Kore", "Puck", "Zephyr"],
        live_default_voice="Kore",
        voice_token_ttl_seconds=90,
        voice_session_max_seconds=1200,
        **kwargs,
    )


REQUEST = ChatRequest(
    model="gemini-4-carbon",
    turns=[
        ChatTurn(role="system", content="Be brief."),
        ChatTurn(role="user", content="Hi"),
        ChatTurn(role="assistant", content="Hello!"),
        ChatTurn(role="user", content="Say thanks"),
    ],
    max_output_tokens=256,
    end_user_id="hashed-user",
)


async def collect(provider: GeminiProvider, request: ChatRequest = REQUEST) -> list[ChatStreamEvent]:
    return [event async for event in provider.stream_chat(request)]


# --------------------------------------------------------------------------- text chat


async def test_streams_text_usage_and_done_with_documented_request_shape() -> None:
    seen: list[httpx2.Request] = []

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen.append(request)
        return sse(
            text_chunk("Thank", responseId="resp-1"),
            text_chunk("s!", finish="STOP", usageMetadata=USAGE, modelVersion="gemini-4-carbon"),
        )

    events = await collect(make_provider(handler))

    assert [e.type for e in events] == ["text_delta", "text_delta", "usage", "done"]
    assert "".join(e.text or "" for e in events) == "Thanks!"
    usage = events[2].usage
    assert usage is not None
    # Thinking tokens are billed as output.
    assert (usage.input_tokens, usage.output_tokens, usage.total_tokens) == (12, 5, 17)
    assert events[3].provider_metadata == {"response_id": "resp-1", "model_version": "gemini-4-carbon"}

    [request] = seen
    assert request.method == "POST"
    assert request.url.path == "/v1beta/models/gemini-4-carbon:streamGenerateContent"
    assert request.url.params["alt"] == "sse"
    assert request.headers["x-goog-api-key"] == "server-gemini-key"
    body = json.loads(request.content)
    assert body["contents"] == [
        {"role": "user", "parts": [{"text": "Hi"}]},
        {"role": "model", "parts": [{"text": "Hello!"}]},
        {"role": "user", "parts": [{"text": "Say thanks"}]},
    ]
    assert body["systemInstruction"]["parts"] == [{"text": "Be brief."}]
    assert body["generationConfig"] == {"maxOutputTokens": 256}
    assert body["store"] is False  # conversations are stored by us, not by Google
    # Deprecated sampling parameters and identifiers are never sent.
    assert "temperature" not in json.dumps(body)
    assert "hashed-user" not in json.dumps(body)


async def test_thought_parts_are_not_shown() -> None:
    def handler(_: httpx2.Request) -> httpx2.Response:
        chunk = {
            "candidates": [
                {
                    "content": {"role": "model", "parts": [{"text": "pondering", "thought": True}, {"text": "Hi"}]},
                    "finishReason": "STOP",
                }
            ]
        }
        return sse(chunk)

    events = await collect(make_provider(handler))
    assert [e.text for e in events if e.type == "text_delta"] == ["Hi"]


async def test_max_tokens_keeps_partial_text() -> None:
    events = await collect(make_provider(lambda _: sse(text_chunk("Partial", finish="MAX_TOKENS"))))
    assert events[-1].type == "done"
    assert events[-1].provider_metadata == {"incomplete_reason": "max_output_tokens"}


async def test_safety_stop_keeps_text_or_reports_a_block() -> None:
    events = await collect(make_provider(lambda _: sse(text_chunk("Some", finish="SAFETY"))))
    assert events[-1].provider_metadata == {"incomplete_reason": "content_filter"}

    blocked = {"promptFeedback": {"blockReason": "PROHIBITED_CONTENT"}}
    events = await collect(make_provider(lambda _: sse(blocked)))
    assert [e.type for e in events] == ["error"]
    assert events[0].error_code == "provider_content_blocked"

    empty_safety = {"candidates": [{"content": {"role": "model", "parts": []}, "finishReason": "SAFETY"}]}
    events = await collect(make_provider(lambda _: sse(empty_safety)))
    assert events[-1].error_code == "provider_content_blocked"


async def test_stream_that_ends_without_finish_reason() -> None:
    events = await collect(make_provider(lambda _: sse(text_chunk("Hel"))))
    assert events[-1].type == "error"
    assert events[-1].error_code == "provider_stream_interrupted"


@pytest.mark.parametrize(
    ("status", "api_status", "message", "expected_code"),
    [
        (400, "INVALID_ARGUMENT", "API key not valid. Please pass a valid API key.", "provider_auth_failed"),
        (403, "PERMISSION_DENIED", "secret account detail", "provider_auth_failed"),
        (404, "NOT_FOUND", "secret account detail", "provider_model_unavailable"),
        (400, "INVALID_ARGUMENT", "secret account detail", "provider_bad_request"),
        (429, "RESOURCE_EXHAUSTED", "secret account detail", "provider_rate_limited"),
        (500, "INTERNAL", "secret account detail", "provider_unavailable"),
        (503, "UNAVAILABLE", "secret account detail", "provider_unavailable"),
        (504, "DEADLINE_EXCEEDED", "secret account detail", "provider_timeout"),
    ],
)
async def test_http_errors_map_to_safe_codes(status: int, api_status: str, message: str, expected_code: str) -> None:
    def handler(_: httpx2.Request) -> httpx2.Response:
        return httpx2.Response(status, json={"error": {"code": status, "message": message, "status": api_status}})

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


def test_models_are_listed_with_verified_names_default_and_live_capabilities() -> None:
    provider = make_provider(lambda _: httpx2.Response(200))
    models = provider.list_models()
    assert [(m.id, m.display_name, m.is_default) for m in models] == [
        ("gemini-4-hydrogen", "Gemini 4 Hydrogen", True),
        ("gemini-4-carbon", "Gemini 4 Carbon", False),
        ("gemini-3.5-flash-lite", "Gemini 3.5 Flash-Lite", False),
        ("gemini-3.8-live", "Gemini 3.8 Live", False),
    ]
    live = models[-1].capabilities
    assert live.realtime_voice and live.server_vad and live.interruption
    assert not live.text_streaming
    assert [(v.id, v.display_name) for v in live.voices] == [
        ("Kore", "Kore (Firm)"),
        ("Puck", "Puck (Upbeat)"),
        ("Zephyr", "Zephyr (Bright)"),
    ]
    assert live.speaking_rate is None  # no rate parameter for native audio
    assert all(m.capabilities.text_streaming for m in models[:-1])


def test_registry_enables_gemini_with_a_key_and_both_providers_together(tmp_path: Path) -> None:
    registry = build_provider_registry(make_settings(tmp_path, gemini_api_key="g-test", gemini_models="gemini-4-neon"))
    [provider] = registry.list()
    assert provider.id == "gemini"
    assert [m.id for m in provider.list_models()] == ["gemini-4-neon", "gemini-3.8-live"]

    both = build_provider_registry(
        make_settings(tmp_path, openai_api_key="sk-test", gemini_api_key="g-test", default_ai_provider="gemini")
    )
    assert [p.id for p in both.list()] == ["openai", "gemini"]
    assert both.default_id == "gemini"

    voiceless = build_provider_registry(make_settings(tmp_path, gemini_api_key="g-test", gemini_live_model=""))
    assert not any(m.capabilities.realtime_voice for m in voiceless.list()[0].list_models())


async def test_chat_service_picks_gemini_text_models_only(app: FastAPI) -> None:
    from app.services.chat_service import ChatService

    provider = make_provider(lambda _: httpx2.Response(500))
    service = ChatService(app.state.db.sessionmaker, ProviderRegistry([provider]), app.state.settings)
    assert service._resolve_target("gemini", "gemini-3.8-live")[1].id == "gemini-4-hydrogen"
    assert service._resolve_target("gemini", "gemini-4-carbon")[1].id == "gemini-4-carbon"


# --------------------------------------------------------------------------- Live API tokens


def token_handler(seen: list[httpx2.Request], expire: str = "2030-01-01T00:20:00Z") -> Handler:
    def handler(request: httpx2.Request) -> httpx2.Response:
        seen.append(request)
        body = json.loads(request.content)
        return httpx2.Response(
            200,
            json={
                "name": "auth_tokens/ephemeral-123",
                "expireTime": expire,
                "newSessionExpireTime": body["newSessionExpireTime"],
                "uses": 1,
            },
        )

    return handler


async def test_live_token_locks_the_session_configuration() -> None:
    seen: list[httpx2.Request] = []
    provider = make_provider(token_handler(seen))
    before = datetime.now(UTC)
    descriptor = await provider.create_realtime_session(
        RealtimeSessionRequest(
            model="gemini-3.8-live",
            voice="Puck",
            language="id-ID",
            instructions="Be brief.",
            server_vad=True,
            speaking_rate=1.4,  # not supported: ignored
            end_user_id="hashed-user",
        )
    )

    [request] = seen
    assert request.method == "POST"
    assert request.url.path == "/v1beta/auth_tokens"
    assert request.headers["x-goog-api-key"] == "server-gemini-key"
    body = json.loads(request.content)
    assert body["uses"] == 1
    connect_by = datetime.fromisoformat(body["newSessionExpireTime"])
    session_end = datetime.fromisoformat(body["expireTime"])
    assert timedelta(seconds=85) < connect_by - before < timedelta(seconds=95)
    assert timedelta(seconds=1195) < session_end - before < timedelta(seconds=1205)
    # No lock_additional_fields: the whole configuration is locked.
    assert "fieldMask" not in body
    setup = body["bidiGenerateContentSetup"]
    assert setup["model"] == "models/gemini-3.8-live"
    assert setup["generationConfig"]["responseModalities"] == ["AUDIO"]
    assert setup["generationConfig"]["speechConfig"]["voice_config"]["prebuilt_voice_config"]["voice_name"] == "Puck"
    assert setup["systemInstruction"]["parts"] == [{"text": "Be brief."}]
    assert setup["inputAudioTranscription"] == {} and setup["outputAudioTranscription"] == {}
    assert setup["sessionResumption"] == {}
    assert "contextWindowCompression" in setup
    assert "realtimeInputConfig" not in setup  # hands-free: automatic activity detection
    assert "hashed-user" not in request.content.decode()
    assert "1.4" not in json.dumps(setup)

    assert descriptor.transport == "websocket"
    assert descriptor.client_secret.get_secret_value() == "auth_tokens/ephemeral-123"
    assert descriptor.endpoint == (
        "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta."
        "GenerativeService.BidiGenerateContentConstrained"
    )
    assert descriptor.expires_at == connect_by
    assert descriptor.config["session_expires_at"] == datetime(2030, 1, 1, 0, 20, tzinfo=UTC)
    assert descriptor.config["input_audio_format"] == "audio/pcm;rate=16000"
    assert descriptor.config["output_sample_rate"] == 24000
    assert descriptor.config["voice"] == "Puck"
    assert "server-gemini-key" not in descriptor.model_dump_json()


async def test_push_to_talk_disables_activity_detection_and_unknown_voice_uses_default() -> None:
    seen: list[httpx2.Request] = []
    provider = make_provider(token_handler(seen), base_url="http://127.0.0.1:9200/")
    descriptor = await provider.create_realtime_session(
        RealtimeSessionRequest(model="gemini-3.8-live", voice="marin", server_vad=False)
    )
    setup = json.loads(seen[0].content)["bidiGenerateContentSetup"]
    assert setup["realtimeInputConfig"] == {"automatic_activity_detection": {"disabled": True}}
    assert setup["generationConfig"]["speechConfig"]["voice_config"]["prebuilt_voice_config"]["voice_name"] == "Kore"
    assert "systemInstruction" not in setup
    # Follows GEMINI_BASE_URL (plain ws:// for the local test server).
    assert descriptor.endpoint == (
        "ws://127.0.0.1:9200/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained"
    )


async def test_live_errors_and_capability_checks() -> None:
    provider = make_provider(
        lambda _: httpx2.Response(
            429, json={"error": {"code": 429, "message": "quota", "status": "RESOURCE_EXHAUSTED"}}
        )
    )
    with pytest.raises(ProviderError) as failure:
        await provider.create_realtime_session(RealtimeSessionRequest(model="gemini-3.8-live"))
    assert failure.value.code == "provider_rate_limited"
    assert failure.value.retryable

    with pytest.raises(CapabilityNotSupportedError):
        await provider.create_realtime_session(RealtimeSessionRequest(model="gemini-4-hydrogen"))


# --------------------------------------------------------------------------- through the API


async def test_voice_session_api_with_gemini(client: AsyncClient, auth_headers: dict[str, str], app: FastAPI) -> None:
    seen: list[httpx2.Request] = []
    app.state.providers = ProviderRegistry([make_provider(token_handler(seen))])

    response = await client.post(f"{API}/voice/sessions", json={}, headers=auth_headers)
    assert response.status_code == 201, response.text
    session = response.json()
    assert (session["provider"], session["model"], session["transport"]) == ("gemini", "gemini-3.8-live", "websocket")
    assert session["client_secret"] == "auth_tokens/ephemeral-123"
    assert session["input_audio_format"] == "audio/pcm;rate=16000"
    assert session["output_sample_rate"] == 24000
    assert session["session_expires_at"].startswith("2030-01-01T00:20:00")
    assert session["data_channel"] is None
    assert session["voice"] == "Kore"

    providers = (await client.get(f"{API}/providers", headers=auth_headers)).json()
    assert providers["default_provider"] == "gemini"
    [gemini] = providers["items"]
    live = next(m for m in gemini["models"] if m["id"] == "gemini-3.8-live")
    assert live["capabilities"]["speaking_rate"] is None
    assert live["capabilities"]["voices"][0] == {"id": "Kore", "display_name": "Kore (Firm)", "language_hints": []}

import json
import time
from typing import Any

import httpx2
import pytest
from fastapi import FastAPI
from httpx import AsyncClient

from app.ai_providers.base import (
    CapabilityNotSupportedError,
    ChatRequest,
    ChatTurn,
    ProviderError,
    RealtimeSessionRequest,
)
from app.ai_providers.openai_provider import OpenAIProvider
from app.ai_providers.registry import ProviderRegistry
from tests.conftest import RegisterFn
from tests.fakes.mock_provider import MockProvider

API = "/api/v1"


@pytest.fixture
def provider(app: FastAPI) -> MockProvider:
    mock = MockProvider()
    app.state.providers = ProviderRegistry([mock])
    return mock


async def start(client: AsyncClient, headers: dict[str, str], **body: Any) -> dict[str, Any]:
    response = await client.post(f"{API}/voice/sessions", json=body, headers=headers)
    assert response.status_code == 201, response.text
    return response.json()


# --------------------------------------------------------------------------- sessions


async def test_start_session_returns_a_short_lived_secret_and_a_new_conversation(
    client: AsyncClient, auth_headers: dict[str, str], provider: MockProvider
) -> None:
    response = await client.post(f"{API}/voice/sessions", json={}, headers=auth_headers)
    assert response.status_code == 201
    assert response.headers["cache-control"] == "no-store"
    session = response.json()
    assert session["client_secret"] == "ephemeral-test-secret"
    assert session["transport"] == "webrtc"
    assert session["data_channel"] == "oai-events"
    assert (session["provider"], session["model"]) == ("mock", "mock-voice")
    assert session["push_to_talk"] is False

    conversation = await client.get(f"{API}/conversations/{session['conversation_id']}", headers=auth_headers)
    assert conversation.status_code == 200
    [request] = provider.realtime_requests
    assert request.server_vad is True
    assert request.end_user_id is not None and "@" not in request.end_user_id


async def test_session_uses_voice_preferences_and_conversation_context(
    client: AsyncClient, auth_headers: dict[str, str], provider: MockProvider
) -> None:
    await client.patch(
        f"{API}/users/me/preferences",
        json={"voice_mode": "push_to_talk", "voice_name": "alpha", "speaking_rate": 1.2, "language": "id-ID"},
        headers=auth_headers,
    )
    conversation = (await client.post(f"{API}/conversations", json={}, headers=auth_headers)).json()
    await client.post(
        f"{API}/conversations/{conversation['id']}/messages",
        json={"content": "Plan a Bandung trip"},
        headers=auth_headers,
    )

    session = await start(client, auth_headers, conversation_id=conversation["id"])
    assert session["conversation_id"] == conversation["id"]
    assert session["push_to_talk"] is True
    [request] = provider.realtime_requests
    assert (request.server_vad, request.voice, request.speaking_rate, request.language) == (
        False,
        "alpha",
        1.2,
        "id-ID",
    )
    assert "Plan a Bandung trip" in (request.instructions or "")
    assert "id-ID" in (request.instructions or "")


async def test_unknown_voice_preference_falls_back_to_provider_default(
    client: AsyncClient, auth_headers: dict[str, str], provider: MockProvider
) -> None:
    await client.patch(f"{API}/users/me/preferences", json={"voice_name": "not-a-voice"}, headers=auth_headers)
    await start(client, auth_headers)
    assert provider.realtime_requests[0].voice is None


class SecondMock(MockProvider):
    id = "second"
    display_name = "Second Mock"


async def test_voice_model_preference_picks_the_provider_and_requests_override_it(
    client: AsyncClient, auth_headers: dict[str, str], app: FastAPI
) -> None:
    first, second = MockProvider(), SecondMock()
    app.state.providers = ProviderRegistry([first, second])

    assert (await start(client, auth_headers))["provider"] == "mock"  # server default

    response = await client.patch(
        f"{API}/users/me/preferences",
        json={"voice_provider": "second", "voice_model": "mock-voice"},
        headers=auth_headers,
    )
    assert response.status_code == 200
    assert (response.json()["voice_provider"], response.json()["voice_model"]) == ("second", "mock-voice")
    assert (await start(client, auth_headers))["provider"] == "second"
    assert (await start(client, auth_headers, provider="mock"))["provider"] == "mock"

    # A preference for a provider that is no longer configured falls back to the default.
    await client.patch(f"{API}/users/me/preferences", json={"voice_provider": "gone"}, headers=auth_headers)
    assert (await start(client, auth_headers))["provider"] == "mock"
    assert len(first.realtime_requests) == 3 and len(second.realtime_requests) == 1


async def test_no_realtime_provider(client: AsyncClient, auth_headers: dict[str, str], app: FastAPI) -> None:
    app.state.providers = ProviderRegistry()
    response = await client.post(f"{API}/voice/sessions", json={}, headers=auth_headers)
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "provider_not_available"


async def test_provider_failure_is_a_502_and_creates_nothing(
    client: AsyncClient, auth_headers: dict[str, str], provider: MockProvider
) -> None:
    provider.realtime_error = ProviderError("quota", code="provider_rate_limited", retryable=True)
    response = await client.post(f"{API}/voice/sessions", json={}, headers=auth_headers)
    assert response.status_code == 502
    assert response.json()["error"]["code"] == "provider_rate_limited"
    assert (await client.get(f"{API}/conversations", headers=auth_headers)).json()["items"] == []


async def test_cannot_start_voice_in_someone_elses_conversation(
    client: AsyncClient, register: RegisterFn, provider: MockProvider
) -> None:
    owner = {"Authorization": f"Bearer {(await register('owner@example.com'))['tokens']['access_token']}"}
    other = {"Authorization": f"Bearer {(await register('other@example.com'))['tokens']['access_token']}"}
    conversation = (await client.post(f"{API}/conversations", json={}, headers=owner)).json()
    response = await client.post(f"{API}/voice/sessions", json={"conversation_id": conversation["id"]}, headers=other)
    assert response.status_code == 404
    assert provider.realtime_requests == []


async def test_requires_authentication(client: AsyncClient) -> None:
    assert (await client.post(f"{API}/voice/sessions", json={})).status_code == 401


# --------------------------------------------------------------------------- transcripts


async def test_transcripts_become_conversation_messages(
    client: AsyncClient, auth_headers: dict[str, str], provider: MockProvider
) -> None:
    session = await start(client, auth_headers)
    url = f"{API}/voice/sessions/{session['id']}/transcripts"

    user = await client.post(
        url,
        json={"role": "user", "content": "What's the weather like in Bandung?", "item_id": "item_1"},
        headers=auth_headers,
    )
    assistant = await client.post(
        url, json={"role": "assistant", "content": "Usually cool and rainy.", "item_id": "item_2"}, headers=auth_headers
    )
    assert user.status_code == assistant.status_code == 201
    assert user.json()["audio_metadata"]["source"] == "voice"
    assert assistant.json()["model"] == "mock-voice"

    messages = (
        await client.get(f"{API}/conversations/{session['conversation_id']}/messages", headers=auth_headers)
    ).json()["items"]
    assert [(m["role"], m["content"]) for m in messages] == [
        ("user", "What's the weather like in Bandung?"),
        ("assistant", "Usually cool and rainy."),
    ]
    conversation = (await client.get(f"{API}/conversations/{session['conversation_id']}", headers=auth_headers)).json()
    assert conversation["title"] == "What's the weather like in Bandung?"


async def test_transcript_upload_is_idempotent_per_item(
    client: AsyncClient, auth_headers: dict[str, str], provider: MockProvider
) -> None:
    session = await start(client, auth_headers)
    url = f"{API}/voice/sessions/{session['id']}/transcripts"
    body = {"role": "user", "content": "Hello", "item_id": "item_9"}
    first = (await client.post(url, json=body, headers=auth_headers)).json()
    second = (await client.post(url, json=body, headers=auth_headers)).json()
    assert first["id"] == second["id"]
    messages = (
        await client.get(f"{API}/conversations/{session['conversation_id']}/messages", headers=auth_headers)
    ).json()["items"]
    assert len(messages) == 1


async def test_transcript_validation_and_ownership(
    client: AsyncClient, register: RegisterFn, provider: MockProvider
) -> None:
    owner = {"Authorization": f"Bearer {(await register('owner@example.com'))['tokens']['access_token']}"}
    other = {"Authorization": f"Bearer {(await register('other@example.com'))['tokens']['access_token']}"}
    session = await start(client, owner)
    url = f"{API}/voice/sessions/{session['id']}/transcripts"
    assert (await client.post(url, json={"role": "system", "content": "x"}, headers=owner)).status_code == 422
    assert (await client.post(url, json={"role": "user", "content": "   "}, headers=owner)).status_code == 422
    response = await client.post(url, json={"role": "user", "content": "hi"}, headers=other)
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "voice_session_not_found"


async def test_end_session(client: AsyncClient, auth_headers: dict[str, str], provider: MockProvider) -> None:
    session = await start(client, auth_headers)
    assert (await client.post(f"{API}/voice/sessions/{session['id']}/end", headers=auth_headers)).status_code == 204
    assert (await client.post(f"{API}/voice/sessions/{session['id']}/end", headers=auth_headers)).status_code == 204


async def test_providers_endpoint_separates_text_and_voice_models(
    client: AsyncClient, auth_headers: dict[str, str], provider: MockProvider
) -> None:
    models = (await client.get(f"{API}/providers", headers=auth_headers)).json()["items"][0]["models"]
    voice = next(m for m in models if m["id"] == "mock-voice")
    assert voice["capabilities"]["realtime_voice"] is True
    assert voice["capabilities"]["voices"][0]["id"] == "alpha"


# --------------------------------------------------------------------------- OpenAI adapter


def realtime_provider(handler: Any, base_url: str | None = None) -> OpenAIProvider:
    return OpenAIProvider(
        api_key="sk-server-key",
        models=["gpt-6.2-astra"],
        default_model="gpt-6.2-astra",
        base_url=base_url,
        max_retries=0,
        http_client=httpx2.AsyncClient(transport=httpx2.MockTransport(handler)),
        realtime_model="gpt-realtime-2.1",
        realtime_voices=["marin", "cedar", "alloy"],
        realtime_default_voice="marin",
        transcription_model="gpt-realtime-whisper",
        voice_token_ttl_seconds=90,
    )


async def test_openai_mints_a_client_secret_with_the_documented_request() -> None:
    seen: list[httpx2.Request] = []
    expires = int(time.time()) + 90

    def handler(request: httpx2.Request) -> httpx2.Response:
        seen.append(request)
        return httpx2.Response(
            200,
            json={
                "value": "ek_test_123",
                "expires_at": expires,
                "session": {"type": "realtime", "model": "gpt-realtime-2.1"},
            },
        )

    provider = realtime_provider(handler)
    descriptor = await provider.create_realtime_session(
        RealtimeSessionRequest(
            model="gpt-realtime-2.1",
            voice="cedar",
            language="id-ID",
            instructions="Be brief.",
            server_vad=True,
            speaking_rate=9.0,  # clamped to the documented max
            end_user_id="hashed-user",
        )
    )

    [request] = seen
    assert request.method == "POST"
    assert request.url.path.endswith("/realtime/client_secrets")
    assert request.headers["authorization"] == "Bearer sk-server-key"
    assert request.headers["openai-safety-identifier"] == "hashed-user"
    body = json.loads(request.content)
    assert body["expires_after"] == {"anchor": "created_at", "seconds": 90}
    session = body["session"]
    assert (session["type"], session["model"], session["instructions"]) == ("realtime", "gpt-realtime-2.1", "Be brief.")
    assert session["audio"]["output"] == {"voice": "cedar", "speed": 1.5}
    assert session["audio"]["input"]["transcription"] == {"model": "gpt-realtime-whisper", "language": "id"}
    assert session["audio"]["input"]["turn_detection"] == {
        "type": "semantic_vad",
        "eagerness": "auto",
        "create_response": True,
        "interrupt_response": True,
    }

    assert descriptor.client_secret.get_secret_value() == "ek_test_123"
    assert int(descriptor.expires_at.timestamp()) == expires
    assert descriptor.transport == "webrtc"
    assert descriptor.endpoint == "https://api.openai.com/v1/realtime/calls"
    assert descriptor.config["data_channel"] == "oai-events"
    assert "sk-server-key" not in descriptor.model_dump_json()


async def test_push_to_talk_disables_turn_detection_and_unknown_voice_uses_default() -> None:
    bodies: list[dict[str, Any]] = []

    def handler(request: httpx2.Request) -> httpx2.Response:
        bodies.append(json.loads(request.content))
        return httpx2.Response(200, json={"value": "ek", "expires_at": int(time.time()) + 60, "session": {}})

    provider = realtime_provider(handler, base_url="http://127.0.0.1:9100/v1")
    descriptor = await provider.create_realtime_session(
        RealtimeSessionRequest(model="gpt-realtime-2.1", voice="nonexistent", server_vad=False)
    )
    session = bodies[0]["session"]
    assert session["audio"]["input"]["turn_detection"] is None
    assert session["audio"]["output"] == {"voice": "marin"}
    assert descriptor.endpoint == "http://127.0.0.1:9100/v1/realtime/calls"  # follows OPENAI_BASE_URL


async def test_openai_realtime_errors_and_capabilities() -> None:
    provider = realtime_provider(lambda _: httpx2.Response(401, json={"error": {"message": "bad key"}}))
    with pytest.raises(ProviderError) as failure:
        await provider.create_realtime_session(RealtimeSessionRequest(model="gpt-realtime-2.1"))
    assert failure.value.code == "provider_auth_failed"

    with pytest.raises(CapabilityNotSupportedError):
        await provider.create_realtime_session(RealtimeSessionRequest(model="gpt-6.2-astra"))

    models = {m.id: m for m in provider.list_models()}
    realtime = models["gpt-realtime-2.1"].capabilities
    assert realtime.realtime_voice and realtime.server_vad and realtime.interruption
    assert [v.id for v in realtime.voices] == ["marin", "cedar", "alloy"]
    assert (realtime.speaking_rate.min, realtime.speaking_rate.max) == (0.25, 1.5)
    assert not realtime.text_streaming
    assert not models["gpt-6.2-astra"].capabilities.realtime_voice


async def test_chat_never_uses_a_realtime_model(client: AsyncClient, app: FastAPI) -> None:
    from app.core.config import Settings
    from app.services.chat_service import ChatService

    provider = realtime_provider(lambda _: httpx2.Response(500))
    service = ChatService(app.state.db.sessionmaker, ProviderRegistry([provider]), app.state.settings)
    _, model = service._resolve_target("openai", "gpt-realtime-2.1")
    assert model.id == "gpt-6.2-astra"
    assert isinstance(app.state.settings, Settings)
    assert ChatRequest(model=model.id, turns=[ChatTurn(role="user", content="hi")]).model == "gpt-6.2-astra"

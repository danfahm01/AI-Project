from pathlib import Path

import pytest
from fastapi import FastAPI
from httpx import AsyncClient

from app.ai_providers.base import ChatRequest, ChatTurn, RealtimeSessionRequest
from app.ai_providers.registry import ProviderNotAvailableError, ProviderRegistry, build_provider_registry
from tests.conftest import make_settings
from tests.fakes.mock_provider import MockProvider


def test_registry_resolves_default_and_rejects_unknown() -> None:
    registry = ProviderRegistry([MockProvider()])
    assert registry.default_id == "mock"
    assert registry.resolve(None).id == "mock"
    with pytest.raises(ProviderNotAvailableError):
        registry.get("nope")


def test_registry_rejects_duplicates() -> None:
    with pytest.raises(ValueError, match="already registered"):
        ProviderRegistry([MockProvider(), MockProvider()])


def test_empty_registry_reports_no_provider() -> None:
    registry = ProviderRegistry()
    assert registry.default_id is None
    with pytest.raises(ProviderNotAvailableError):
        registry.resolve(None)


def test_configured_default_is_ignored_when_not_registered() -> None:
    registry = ProviderRegistry([MockProvider()], default_provider="gemini")
    assert registry.default_id == "mock"


def test_registry_is_empty_without_api_keys(tmp_path: Path) -> None:
    assert build_provider_registry(make_settings(tmp_path)).list() == []


async def test_adapter_contract_stream_ends_with_terminal_event() -> None:
    provider = MockProvider()
    request = ChatRequest(model="mock-text", turns=[ChatTurn(role="user", content="hello there")])
    events = [event async for event in provider.stream_chat(request)]
    assert "".join(e.text or "" for e in events if e.type == "text_delta").strip() == "hello there"
    assert events[-1].type == "done"
    assert sum(e.type in ("done", "error") for e in events) == 1

    failing = [e async for e in MockProvider(fail_with="boom").stream_chat(request)]
    assert [e.type for e in failing] == ["error"]


async def test_realtime_descriptor_never_serialises_secret_by_default() -> None:
    descriptor = await MockProvider().create_realtime_session(RealtimeSessionRequest(model="mock-voice"))
    assert "ephemeral-test-secret" not in descriptor.model_dump_json()
    assert descriptor.client_secret.get_secret_value() == "ephemeral-test-secret"


def test_capability_helpers() -> None:
    provider = MockProvider()
    default = provider.default_model()
    assert default is not None
    assert default.id == "mock-voice"
    assert provider.get_model("mock-text").capabilities.realtime_voice is False
    assert provider.get_model("missing") is None


async def test_providers_endpoint_empty_in_phase1(client: AsyncClient, auth_headers: dict[str, str]) -> None:
    body = (await client.get("/api/v1/providers", headers=auth_headers)).json()
    assert body == {"items": [], "default_provider": None}


async def test_providers_endpoint_lists_capabilities(
    app: FastAPI, client: AsyncClient, auth_headers: dict[str, str]
) -> None:
    app.state.providers = ProviderRegistry([MockProvider()])
    body = (await client.get("/api/v1/providers", headers=auth_headers)).json()
    assert body["default_provider"] == "mock"
    [provider] = body["items"]
    assert provider["is_default"] is True
    voice_model = provider["models"][0]
    assert voice_model["capabilities"]["realtime_voice"] is True
    assert voice_model["capabilities"]["speaking_rate"] == {"min": 0.5, "max": 2.0, "default": 1.0}
    assert provider["models"][1]["capabilities"]["speaking_rate"] is None


async def test_registry_closes_adapters() -> None:
    provider = MockProvider()
    await ProviderRegistry([provider]).aclose()
    assert provider.closed

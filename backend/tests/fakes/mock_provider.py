"""Deterministic in-memory provider used ONLY by tests. Never registered by the app."""

import asyncio
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta

from pydantic import SecretStr

from app.ai_providers.base import (
    AIProvider,
    ChatRequest,
    ChatStreamEvent,
    ChatUsage,
    ModelInfo,
    NumericRange,
    ProviderCapabilities,
    ProviderError,
    RealtimeSessionDescriptor,
    RealtimeSessionRequest,
    VoiceOption,
)


class MockProvider(AIProvider):
    id = "mock"
    display_name = "Mock Provider"

    def __init__(self, *, fail_with: str | None = None, reply: str | None = None, delay: float = 0.0) -> None:
        self.fail_with = fail_with
        self.reply = reply  # fixed reply; default echoes the last turn
        self.delay = delay  # seconds between chunks (cancellation tests)
        self.closed = False
        self.requests: list[ChatRequest] = []
        self.realtime_requests: list[RealtimeSessionRequest] = []
        self.realtime_error: ProviderError | None = None

    def list_models(self) -> list[ModelInfo]:
        return [
            ModelInfo(
                id="mock-voice",
                display_name="Mock Voice",
                is_default=True,
                capabilities=ProviderCapabilities(
                    text_streaming=True,
                    realtime_voice=True,
                    server_vad=True,
                    interruption=True,
                    voices=[VoiceOption(id="alpha", display_name="Alpha")],
                    languages=["en", "id"],
                    speaking_rate=NumericRange(min=0.5, max=2.0, default=1.0),
                ),
            ),
            ModelInfo(
                id="mock-text",
                display_name="Mock Text",
                capabilities=ProviderCapabilities(text_streaming=True, image_input=True),
            ),
        ]

    async def stream_chat(self, request: ChatRequest) -> AsyncIterator[ChatStreamEvent]:
        self.requests.append(request)
        if self.fail_with:
            yield ChatStreamEvent(type="error", error_code="mock_failure", error_message=self.fail_with)
            return
        echo = self.reply if self.reply is not None else (request.turns[-1].content if request.turns else "")
        for word in echo.split():
            if self.delay:
                await asyncio.sleep(self.delay)
            yield ChatStreamEvent(type="text_delta", text=word + " ")
        tokens = len(echo.split())
        yield ChatStreamEvent(type="usage", usage=ChatUsage(input_tokens=tokens, output_tokens=tokens))
        yield ChatStreamEvent(type="done")

    async def create_realtime_session(self, request: RealtimeSessionRequest) -> RealtimeSessionDescriptor:
        self.realtime_requests.append(request)
        if self.realtime_error is not None:
            raise self.realtime_error
        return RealtimeSessionDescriptor(
            provider=self.id,
            model=request.model,
            transport="webrtc",
            endpoint="https://mock.invalid/v1/realtime/calls",
            client_secret=SecretStr("ephemeral-test-secret"),
            expires_at=datetime.now(UTC) + timedelta(minutes=1),
            config={"voice": request.voice or "alpha", "data_channel": "oai-events"},
        )

    async def aclose(self) -> None:
        self.closed = True

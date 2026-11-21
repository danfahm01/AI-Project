"""Streaming chat over the WebSocket protocol, end to end through the real app
(auth, persistence, rate limits) with the test-only MockProvider."""

import uuid
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pytest
from fastapi import FastAPI
from sqlalchemy import create_engine
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

import app.models  # noqa: F401
from app.ai_providers.registry import ProviderRegistry
from app.db.base import Base
from app.main import create_app
from app.models.message import Message, MessageRole, MessageStatus
from app.services.chat_service import end_user_id, select_history
from tests.conftest import TEST_PASSWORD, make_settings
from tests.fakes.mock_provider import MockProvider

WS_URL = "/api/v1/chat/ws"


@dataclass
class Harness:
    client: TestClient
    app: FastAPI

    def use_provider(self, provider: MockProvider | None) -> None:
        self.app.state.providers = ProviderRegistry([provider] if provider else [])

    def register(self, email: str = "ana@example.com") -> str:
        response = self.client.post(
            "/api/v1/auth/register", json={"email": email, "password": TEST_PASSWORD, "display_name": "Ana"}
        )
        assert response.status_code == 201, response.text
        return response.json()["tokens"]["access_token"]

    def new_conversation(self, token: str) -> str:
        response = self.client.post("/api/v1/conversations", json={}, headers={"Authorization": f"Bearer {token}"})
        return response.json()["id"]

    def messages(self, token: str, conversation_id: str) -> list[dict[str, Any]]:
        response = self.client.get(
            f"/api/v1/conversations/{conversation_id}/messages", headers={"Authorization": f"Bearer {token}"}
        )
        return response.json()["items"]


def make_harness(tmp_path: Path, **overrides: Any) -> Iterator[Harness]:
    settings = make_settings(tmp_path, **overrides)
    engine = create_engine(f"sqlite:///{(tmp_path / 'test.db').as_posix()}")
    Base.metadata.create_all(engine)
    engine.dispose()
    application = create_app(settings)
    with TestClient(application) as client:
        harness = Harness(client=client, app=application)
        harness.use_provider(MockProvider())
        yield harness


@pytest.fixture
def harness(tmp_path: Path) -> Iterator[Harness]:
    yield from make_harness(tmp_path)


def authed(ws: Any, token: str) -> None:
    ws.send_json({"type": "auth", "token": token})
    assert ws.receive_json()["type"] == "auth.ok"


def read_until(ws: Any, *terminal: str) -> list[dict[str, Any]]:
    events = []
    while True:
        event = ws.receive_json()
        events.append(event)
        if event["type"] in terminal:
            return events


def send(ws: Any, conversation_id: str, content: str, request_id: str = "req-1") -> None:
    ws.send_json(
        {"type": "message.send", "request_id": request_id, "conversation_id": conversation_id, "content": content}
    )


TERMINAL = ("response.completed", "response.failed", "response.cancelled")


# --------------------------------------------------------------------------- auth


def test_first_frame_must_authenticate(harness: Harness) -> None:
    with harness.client.websocket_connect(WS_URL) as ws:
        ws.send_json({"type": "ping"})
        assert ws.receive_json()["type"] == "auth.failed"
        with pytest.raises(WebSocketDisconnect) as closed:
            ws.receive_json()
        assert closed.value.code == 4401


def test_invalid_token_is_rejected(harness: Harness) -> None:
    with harness.client.websocket_connect(WS_URL) as ws:
        ws.send_json({"type": "auth", "token": "not-a-jwt"})
        event = ws.receive_json()
        assert event == {"type": "auth.failed", "error": {"code": "invalid_token", "message": "Invalid access token"}}


def test_ping_pong_and_invalid_commands(harness: Harness) -> None:
    token = harness.register()
    with harness.client.websocket_connect(WS_URL) as ws:
        authed(ws, token)
        ws.send_json({"type": "ping"})
        assert ws.receive_json() == {"type": "pong"}
        ws.send_json({"type": "message.send", "request_id": "r1", "conversation_id": "nope", "content": "x"})
        error = ws.receive_json()
        assert error["type"] == "error"
        assert error["request_id"] == "r1"
        assert error["error"]["code"] == "invalid_command"


# --------------------------------------------------------------------------- streaming


def test_message_is_saved_streamed_and_persisted(harness: Harness) -> None:
    provider = MockProvider(reply="Hello there friend")
    harness.use_provider(provider)
    token = harness.register()
    conversation_id = harness.new_conversation(token)

    with harness.client.websocket_connect(WS_URL) as ws:
        authed(ws, token)
        send(ws, conversation_id, "Greet me please")
        events = read_until(ws, *TERMINAL)

    types = [e["type"] for e in events]
    assert types[:3] == ["message.created", "conversation.updated", "response.started"]
    assert types[-1] == "response.completed"
    assert all(e["request_id"] == "req-1" and e["conversation_id"] == conversation_id for e in events)

    user_message = events[0]["message"]
    assert (user_message["role"], user_message["content"]) == ("user", "Greet me please")
    assert events[1]["conversation"]["title"] == "Greet me please"
    assert events[1]["title_changed"] is True
    started = events[2]["message"]
    assert (started["role"], started["status"], started["content"]) == ("assistant", "streaming", "")

    deltas = [e for e in events if e["type"] == "response.delta"]
    assert "".join(d["delta"] for d in deltas).strip() == "Hello there friend"
    assert {d["message_id"] for d in deltas} == {started["id"]}

    final = events[-1]["message"]
    assert final["status"] == "complete"
    assert final["content"].strip() == "Hello there friend"
    assert final["usage"]["output_tokens"] == 3
    assert (final["provider"], final["model"]) == ("mock", "mock-voice")

    stored = harness.messages(token, conversation_id)
    assert [(m["role"], m["status"]) for m in stored] == [("user", "complete"), ("assistant", "complete")]

    # The provider received the system prompt plus the conversation, and a hashed user id.
    [request] = provider.requests
    assert request.turns[0].role == "system"
    assert [(t.role, t.content) for t in request.turns[1:]] == [("user", "Greet me please")]
    assert request.end_user_id is not None
    assert "ana@example.com" not in request.end_user_id


def test_conversation_history_is_sent_on_follow_up(harness: Harness) -> None:
    provider = MockProvider(reply="ok")
    harness.use_provider(provider)
    token = harness.register()
    conversation_id = harness.new_conversation(token)
    with harness.client.websocket_connect(WS_URL) as ws:
        authed(ws, token)
        send(ws, conversation_id, "First", "r1")
        read_until(ws, *TERMINAL)
        send(ws, conversation_id, "Second", "r2")
        read_until(ws, *TERMINAL)

    turns = [(t.role, t.content.strip()) for t in provider.requests[-1].turns[1:]]
    assert turns == [("user", "First"), ("assistant", "ok"), ("user", "Second")]


def test_history_loads_only_the_newest_messages(tmp_path: Path) -> None:
    # Long conversations: only CHAT_HISTORY_MAX_MESSAGES are read per reply.
    for harness in make_harness(tmp_path, chat_history_max_messages=3):
        provider = MockProvider(reply="ok")
        harness.use_provider(provider)
        token = harness.register()
        conversation_id = harness.new_conversation(token)
        with harness.client.websocket_connect(WS_URL) as ws:
            authed(ws, token)
            for index, text in enumerate(("One", "Two", "Three")):
                send(ws, conversation_id, text, f"r{index}")
                read_until(ws, *TERMINAL)

        turns = [(t.role, t.content.strip()) for t in provider.requests[-1].turns[1:]]
        assert turns == [("user", "Two"), ("assistant", "ok"), ("user", "Three")]


def test_provider_failure_is_persisted_as_error(harness: Harness) -> None:
    harness.use_provider(MockProvider(fail_with="boom"))
    token = harness.register()
    conversation_id = harness.new_conversation(token)
    with harness.client.websocket_connect(WS_URL) as ws:
        authed(ws, token)
        send(ws, conversation_id, "Hi")
        events = read_until(ws, *TERMINAL)

    failed = events[-1]
    assert failed["type"] == "response.failed"
    assert failed["error"]["code"] == "mock_failure"
    assert failed["message"]["status"] == "error"
    assert failed["message"]["metadata"]["error"]["code"] == "mock_failure"


def test_without_a_provider_the_user_message_is_kept_and_the_reply_fails(harness: Harness) -> None:
    harness.use_provider(None)
    token = harness.register()
    conversation_id = harness.new_conversation(token)
    with harness.client.websocket_connect(WS_URL) as ws:
        authed(ws, token)
        send(ws, conversation_id, "Anyone there?")
        events = read_until(ws, *TERMINAL)

    assert [e["type"] for e in events] == ["message.created", "conversation.updated", "response.failed"]
    assert events[-1]["message"] is None
    assert events[-1]["error"]["code"] == "provider_not_available"
    assert [m["role"] for m in harness.messages(token, conversation_id)] == ["user"]


def test_regenerate_replaces_the_last_reply(harness: Harness) -> None:
    harness.use_provider(MockProvider(reply="first answer"))
    token = harness.register()
    conversation_id = harness.new_conversation(token)
    with harness.client.websocket_connect(WS_URL) as ws:
        authed(ws, token)
        send(ws, conversation_id, "Question")
        first = read_until(ws, *TERMINAL)[-1]["message"]

        harness.use_provider(MockProvider(reply="second answer"))
        ws.send_json({"type": "response.regenerate", "request_id": "r2", "conversation_id": conversation_id})
        events = read_until(ws, *TERMINAL)

    assert events[0] == {
        "type": "message.deleted",
        "request_id": "r2",
        "conversation_id": conversation_id,
        "message_id": first["id"],
    }
    assert events[-1]["message"]["content"].strip() == "second answer"
    stored = harness.messages(token, conversation_id)
    assert [m["content"].strip() for m in stored] == ["Question", "second answer"]


def test_regenerate_after_edit_answers_the_edited_message(harness: Harness) -> None:
    harness.use_provider(MockProvider())  # echoes the last user turn
    token = harness.register()
    conversation_id = harness.new_conversation(token)
    headers = {"Authorization": f"Bearer {token}"}
    with harness.client.websocket_connect(WS_URL) as ws:
        authed(ws, token)
        send(ws, conversation_id, "original")
        user_id = read_until(ws, *TERMINAL)[0]["message"]["id"]

        edited = harness.client.patch(f"/api/v1/messages/{user_id}", json={"content": "edited"}, headers=headers)
        assert len(edited.json()["removed_message_ids"]) == 1
        ws.send_json({"type": "response.regenerate", "request_id": "r2", "conversation_id": conversation_id})
        events = read_until(ws, *TERMINAL)

    assert "message.deleted" not in [e["type"] for e in events]
    assert events[-1]["message"]["content"].strip() == "edited"


def test_cancel_keeps_the_partial_reply(harness: Harness) -> None:
    harness.use_provider(MockProvider(reply="one two three four five six seven eight nine ten", delay=0.05))
    token = harness.register()
    conversation_id = harness.new_conversation(token)
    with harness.client.websocket_connect(WS_URL) as ws:
        authed(ws, token)
        send(ws, conversation_id, "Count")
        read_until(ws, "response.delta")
        ws.send_json({"type": "response.cancel", "request_id": "req-1"})
        events = read_until(ws, *TERMINAL)

    cancelled = events[-1]
    assert cancelled["type"] == "response.cancelled"
    assert cancelled["message"]["status"] == "cancelled"
    partial = cancelled["message"]["content"]
    assert partial.startswith("one")
    assert len(partial.split()) < 10
    stored = harness.messages(token, conversation_id)[-1]
    assert (stored["status"], stored["content"]) == ("cancelled", partial)


def test_one_generation_at_a_time_per_connection(harness: Harness) -> None:
    harness.use_provider(MockProvider(reply="a b c d e f", delay=0.05))
    token = harness.register()
    conversation_id = harness.new_conversation(token)
    with harness.client.websocket_connect(WS_URL) as ws:
        authed(ws, token)
        send(ws, conversation_id, "First", "r1")
        read_until(ws, "response.started")
        send(ws, conversation_id, "Second", "r2")
        events = read_until(ws, "error")
        assert events[-1]["request_id"] == "r2"
        assert events[-1]["error"]["code"] == "busy"
        read_until(ws, *TERMINAL)


def test_cannot_use_someone_elses_conversation(harness: Harness) -> None:
    owner = harness.register("owner@example.com")
    intruder = harness.register("intruder@example.com")
    conversation_id = harness.new_conversation(owner)
    with harness.client.websocket_connect(WS_URL) as ws:
        authed(ws, intruder)
        send(ws, conversation_id, "Let me in")
        events = read_until(ws, *TERMINAL)
    assert events == [
        {
            "type": "response.failed",
            "request_id": "req-1",
            "conversation_id": conversation_id,
            "message": None,
            "error": {"code": "conversation_not_found", "message": "Conversation not found"},
        }
    ]
    assert harness.messages(owner, conversation_id) == []


def test_chat_rate_limit(tmp_path: Path) -> None:
    for harness in make_harness(tmp_path, rate_limit_chat_per_minute=1):
        token = harness.register()
        conversation_id = harness.new_conversation(token)
        with harness.client.websocket_connect(WS_URL) as ws:
            authed(ws, token)
            send(ws, conversation_id, "one", "r1")
            read_until(ws, *TERMINAL)
            send(ws, conversation_id, "two", "r2")
            error = read_until(ws, "error")[-1]
        assert error["error"]["code"] == "rate_limited"


# --------------------------------------------------------------------------- units


def _message(seq: int, role: MessageRole, content: str, status: MessageStatus = MessageStatus.COMPLETE) -> Message:
    return Message(id=uuid.uuid4(), conversation_id=uuid.uuid4(), seq=seq, role=role, content=content, status=status)


def test_select_history_respects_budget_and_skips_unfinished_turns() -> None:
    history = [
        _message(1, MessageRole.USER, "a" * 50),
        _message(2, MessageRole.ASSISTANT, "b" * 50),
        _message(3, MessageRole.USER, "c" * 50),
        _message(4, MessageRole.ASSISTANT, "partial", MessageStatus.CANCELLED),
        _message(5, MessageRole.USER, "d" * 50),
    ]
    assert [m.seq for m in select_history(history, max_chars=10_000)] == [1, 2, 3, 5]
    # Budget for ~2 messages: oldest dropped, and history never starts with an assistant turn.
    assert [m.seq for m in select_history(history, max_chars=120)] == [3, 5]
    # The newest message is always kept, even if alone it exceeds the budget.
    assert [m.seq for m in select_history(history, max_chars=10)] == [5]


def test_end_user_id_is_a_stable_pseudonym() -> None:
    user_id = uuid.uuid4()
    assert end_user_id(user_id) == end_user_id(user_id)
    assert str(user_id) not in end_user_id(user_id)
    assert len(end_user_id(user_id)) <= 64

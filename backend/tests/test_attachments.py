"""Attachments end to end: upload validation, storage, signed links, sending with
a message over the chat socket, capability checks, history budget and clean-up."""

import base64
import json
import sqlite3
import uuid
from collections.abc import Iterator
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

import httpx2
import pytest

from app.ai_providers.base import ChatAttachment, ChatRequest, ChatTurn
from app.ai_providers.gemini_provider import GeminiProvider
from app.ai_providers.openai_provider import OpenAIProvider
from app.services.attachment_service import AttachmentService, clean_filename, sniff_content_type
from tests.fakes.mock_provider import MockProvider
from tests.test_chat_socket import TERMINAL, WS_URL, Harness, authed, make_harness, read_until

API = "/api/v1"
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + bytes(80)
JPEG = b"\xff\xd8\xff\xe0" + bytes(60)
WEBP = b"RIFF\x24\x00\x00\x00WEBPVP8 " + bytes(40)
PDF = b"%PDF-1.7\n1 0 obj << >> endobj\n%%EOF\n"


@pytest.fixture
def harness(tmp_path: Path) -> Iterator[Harness]:
    yield from make_harness(tmp_path)


def auth(token: str) -> dict[str, str]:
    return {"Authorization": f"Bearer {token}"}


def upload(h: Harness, token: str, data: bytes, name: str = "photo.png", mime: str = "image/png") -> httpx2.Response:
    return h.client.post(f"{API}/attachments", files={"file": (name, data, mime)}, headers=auth(token))


def uploaded(h: Harness, token: str, data: bytes, name: str = "photo.png") -> dict[str, Any]:
    response = upload(h, token, data, name)
    assert response.status_code == 201, response.text
    return response.json()


def use_model(h: Harness, token: str, conversation_id: str, model: str) -> None:
    response = h.client.patch(
        f"{API}/conversations/{conversation_id}", json={"provider": "mock", "model": model}, headers=auth(token)
    )
    assert response.status_code == 200, response.text


def send(ws: Any, conversation_id: str, content: str, ids: list[str], request_id: str = "r1") -> list[dict[str, Any]]:
    ws.send_json(
        {
            "type": "message.send",
            "request_id": request_id,
            "conversation_id": conversation_id,
            "content": content,
            "attachment_ids": ids,
        }
    )
    return read_until(ws, *TERMINAL, "error")


def stored_files(h: Harness) -> list[Path]:
    root = Path(h.app.state.settings.attachment_storage_dir)
    return [p for p in root.rglob("*") if p.is_file()] if root.exists() else []


# --------------------------------------------------------------------------- upload


def test_type_detection_and_file_names() -> None:
    assert sniff_content_type(PNG) == "image/png"
    assert sniff_content_type(JPEG) == "image/jpeg"
    assert sniff_content_type(WEBP) == "image/webp"
    assert sniff_content_type(PDF) == "application/pdf"
    assert sniff_content_type(b"GIF89a....") is None
    assert sniff_content_type(b"<html><script>") is None

    assert clean_filename("C:\\fakepath\\..\\ev<il>.png", "image/png") == "evil.png"
    assert clean_filename("report", "application/pdf") == "report.pdf"
    assert clean_filename("photo.JPEG", "image/jpeg") == "photo.JPEG"
    assert clean_filename("disguised.pdf", "image/png") == "disguised.pdf.png"
    assert clean_filename("\x00\n", "image/webp") == "attachment.webp"
    assert len(clean_filename("x" * 500 + ".png", "image/png")) <= 120


def test_upload_detects_the_type_and_serves_the_file_safely(harness: Harness) -> None:
    token = harness.register()
    response = upload(harness, token, PNG, name="../../etc/passwd.png", mime="text/html")
    assert response.status_code == 201
    attachment = response.json()
    assert attachment["kind"] == "image"
    assert attachment["content_type"] == "image/png"  # from the bytes, not the request
    assert attachment["filename"] == "passwd.png"
    assert attachment["size_bytes"] == len(PNG)
    assert attachment["message_id"] is None and attachment["conversation_id"] is None

    content = harness.client.get(f"{API}/attachments/{attachment['id']}/content", headers=auth(token))
    assert content.status_code == 200
    assert content.content == PNG
    assert content.headers["content-type"] == "image/png"
    assert content.headers["x-content-type-options"] == "nosniff"
    assert content.headers["content-disposition"].startswith('inline; filename="passwd.png"')
    assert len(stored_files(harness)) == 1

    other = harness.register("other@example.com")
    assert harness.client.get(f"{API}/attachments/{attachment['id']}/content", headers=auth(other)).status_code == 404
    assert harness.client.get(f"{API}/attachments/{attachment['id']}").status_code == 401


def test_unsupported_empty_and_oversized_uploads_are_rejected(harness: Harness) -> None:
    token = harness.register()
    rejected = upload(harness, token, b"<html><script>alert(1)</script>", name="x.png")
    assert rejected.status_code == 415
    assert rejected.json()["error"]["code"] == "attachment_type_not_supported"
    assert upload(harness, token, b"").json()["error"]["code"] == "attachment_empty"

    harness.app.state.settings.attachment_max_bytes = 1024
    too_big = upload(harness, token, PNG + bytes(2000))
    assert too_big.status_code == 413
    assert too_big.json()["error"]["code"] == "attachment_too_large"
    assert stored_files(harness) == []

    assert uploaded(harness, token, PDF, "notes")["filename"] == "notes.pdf"
    assert uploaded(harness, token, WEBP, "pic.webp")["kind"] == "image"


def test_signed_links_open_without_a_token_until_they_expire(harness: Harness) -> None:
    token = harness.register()
    attachment = uploaded(harness, token, PDF, "report.pdf")
    link = harness.client.post(f"{API}/attachments/{attachment['id']}/link", headers=auth(token)).json()
    assert link["path"].startswith(f"/attachments/{attachment['id']}/download?expires=")

    download = harness.client.get(API + link["path"])
    assert download.status_code == 200
    assert download.content == PDF
    assert download.headers["content-type"] == "application/pdf"

    tampered = API + link["path"][:-3] + "abc"
    assert harness.client.get(tampered).status_code == 404

    # A correctly signed but expired link is refused too.
    service = AttachmentService(None, None, harness.app.state.settings)  # type: ignore[arg-type]
    expired = int((datetime.now(UTC) - timedelta(seconds=5)).timestamp())
    signature = service._signature(uuid.UUID(attachment["id"]), expired)
    assert not service.verify_signature(uuid.UUID(attachment["id"]), expired, signature)
    response = harness.client.get(
        f"{API}/attachments/{attachment['id']}/download", params={"expires": expired, "signature": signature}
    )
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "attachment_link_invalid"


# --------------------------------------------------------------------------- sending


def test_send_an_image_with_a_message(harness: Harness) -> None:
    provider = MockProvider(reply="A tiny picture")
    harness.use_provider(provider)
    token = harness.register()
    conversation = harness.new_conversation(token)
    use_model(harness, token, conversation, "mock-text")  # accepts images
    image = uploaded(harness, token, PNG)

    with harness.client.websocket_connect(WS_URL) as ws:
        authed(ws, token)
        events = send(ws, conversation, "What is this?", [image["id"]])
    created = next(e for e in events if e["type"] == "message.created")
    assert [a["id"] for a in created["message"]["attachments"]] == [image["id"]]
    assert events[-1]["type"] == "response.completed"

    last_turn = provider.requests[-1].turns[-1]
    assert last_turn.content == "What is this?"
    [sent] = last_turn.attachments
    assert (sent.kind, sent.mime_type, sent.filename, sent.data) == ("image", "image/png", "photo.png", PNG)

    messages = harness.messages(token, conversation)
    assert messages[0]["attachments"][0]["message_id"] == messages[0]["id"]
    assert messages[0]["attachments"][0]["conversation_id"] == conversation
    assert messages[1]["attachments"] == []

    # An attachment belongs to one message.
    with harness.client.websocket_connect(WS_URL) as ws:
        authed(ws, token)
        again = send(ws, conversation, "Again", [image["id"]], request_id="r2")
    assert again[-1]["type"] == "response.failed"
    assert again[-1]["error"]["code"] == "attachment_not_found"
    assert len(harness.messages(token, conversation)) == 2


def test_attachment_only_message_titles_the_conversation(harness: Harness) -> None:
    provider = MockProvider(reply="Got it")
    harness.use_provider(provider)
    token = harness.register()
    conversation = harness.new_conversation(token)
    use_model(harness, token, conversation, "mock-text")
    image = uploaded(harness, token, JPEG, "holiday.jpg")

    with harness.client.websocket_connect(WS_URL) as ws:
        authed(ws, token)
        events = send(ws, conversation, "", [image["id"]])
        ws.send_json({"type": "message.send", "request_id": "r9", "conversation_id": conversation, "content": "  "})
        invalid = ws.receive_json()
    assert events[-1]["type"] == "response.completed"
    assert invalid["type"] == "error" and invalid["error"]["code"] == "invalid_command"
    title = next(e for e in events if e["type"] == "conversation.updated")["conversation"]["title"]
    assert title == "holiday.jpg"
    turn = provider.requests[-1].turns[-1]
    assert turn.content == "" and turn.attachments[0].mime_type == "image/jpeg"


def test_models_without_support_reject_attachments_and_nothing_is_stored(harness: Harness) -> None:
    token = harness.register()
    conversation = harness.new_conversation(token)
    image = uploaded(harness, token, PNG)
    pdf = uploaded(harness, token, PDF, "doc.pdf")

    with harness.client.websocket_connect(WS_URL) as ws:
        authed(ws, token)
        # The default mock model reads text only.
        no_images = send(ws, conversation, "Look", [image["id"]])
        use_model(harness, token, conversation, "mock-text")  # images yes, PDFs no
        no_pdfs = send(ws, conversation, "Read", [image["id"], pdf["id"]], request_id="r2")
        ok = send(ws, conversation, "Look", [image["id"]], request_id="r3")
    assert no_images[-1]["error"] == {
        "code": "attachments_not_supported",
        "message": "Mock Voice cannot read images. Choose another model or remove the attachment.",
    }
    assert [e["type"] for e in no_images] == ["response.failed"]  # no message.created
    assert no_pdfs[-1]["error"]["code"] == "attachments_not_supported"
    assert "PDF documents" in no_pdfs[-1]["error"]["message"]
    assert ok[-1]["type"] == "response.completed"  # the upload was still pending
    assert len(harness.messages(token, conversation)) == 2


def test_limits_per_message(harness: Harness) -> None:
    token = harness.register()
    conversation = harness.new_conversation(token)
    use_model(harness, token, conversation, "mock-text")
    harness.app.state.settings.attachments_per_message = 2
    ids = [uploaded(harness, token, PNG)["id"] for _ in range(3)]
    with harness.client.websocket_connect(WS_URL) as ws:
        authed(ws, token)
        too_many = send(ws, conversation, "x", ids)
        harness.app.state.settings.attachment_context_max_bytes = len(PNG) * 2 - 1
        too_large = send(ws, conversation, "x", ids[:2], request_id="r2")
    assert too_many[-1]["error"]["code"] == "too_many_attachments"
    assert too_large[-1]["error"]["code"] == "attachments_too_large"


def test_history_keeps_newest_files_within_the_budget_and_names_the_rest(harness: Harness) -> None:
    provider = MockProvider(reply="ok")
    harness.use_provider(provider)
    token = harness.register()
    conversation = harness.new_conversation(token)
    use_model(harness, token, conversation, "mock-text")
    harness.app.state.settings.attachment_context_max_bytes = len(PNG) + 10
    first = uploaded(harness, token, PNG, "first.png")
    second = uploaded(harness, token, PNG, "second.png")

    with harness.client.websocket_connect(WS_URL) as ws:
        authed(ws, token)
        send(ws, conversation, "One", [first["id"]])
        send(ws, conversation, "Two", [second["id"]], request_id="r2")

    turns = provider.requests[-1].turns
    user_turns = [t for t in turns if t.role == "user"]
    assert user_turns[0].attachments == []
    assert user_turns[0].content == 'One\n\n[Earlier image "first.png" is not repeated (request size limit).]'
    assert [a.filename for a in user_turns[1].attachments] == ["second.png"]

    # A model that cannot read images gets a note instead of the file.
    use_model(harness, token, conversation, "mock-voice")
    with harness.client.websocket_connect(WS_URL) as ws:
        authed(ws, token)
        send(ws, conversation, "Three", [], request_id="r3")
    notes = [t.content for t in provider.requests[-1].turns if t.role == "user"]
    assert notes[1] == 'Two\n\n[Attached image "second.png": this model cannot read it.]'


# --------------------------------------------------------------------------- clean-up


def test_deleting_uploads_messages_and_conversations_removes_files(harness: Harness) -> None:
    harness.use_provider(MockProvider(reply="ok"))
    token = harness.register()
    pending = uploaded(harness, token, PNG)
    assert harness.client.delete(f"{API}/attachments/{pending['id']}", headers=auth(token)).status_code == 204
    assert stored_files(harness) == []

    conversation = harness.new_conversation(token)
    use_model(harness, token, conversation, "mock-text")
    ids = [uploaded(harness, token, PNG, f"{i}.png")["id"] for i in range(3)]
    with harness.client.websocket_connect(WS_URL) as ws:
        authed(ws, token)
        for index, attachment_id in enumerate(ids):
            send(ws, conversation, f"m{index}", [attachment_id], request_id=f"r{index}")
    assert len(stored_files(harness)) == 3
    sent = harness.client.delete(f"{API}/attachments/{ids[0]}", headers=auth(token))
    assert sent.status_code == 409 and sent.json()["error"]["code"] == "attachment_in_use"

    messages = harness.messages(token, conversation)
    # Deleting the last user message removes its file.
    assert harness.client.delete(f"{API}/messages/{messages[4]['id']}", headers=auth(token)).status_code == 204
    assert len(stored_files(harness)) == 2
    # Editing the first message drops the later turns and their files; its own file stays.
    edit = harness.client.patch(f"{API}/messages/{messages[0]['id']}", json={"content": "m0!"}, headers=auth(token))
    assert edit.status_code == 200
    assert [a["id"] for a in edit.json()["message"]["attachments"]] == [ids[0]]
    assert len(stored_files(harness)) == 1
    assert harness.client.delete(f"{API}/conversations/{conversation}", headers=auth(token)).status_code == 204
    assert stored_files(harness) == []


def test_stale_pending_uploads_are_purged(harness: Harness, tmp_path: Path) -> None:
    token = harness.register()
    old = uploaded(harness, token, PNG)
    with sqlite3.connect(tmp_path / "test.db") as db:
        stamp = db.execute("SELECT created_at FROM conversation_attachments").fetchone()[0]
        db.execute("UPDATE conversation_attachments SET created_at = ?", ("2020" + str(stamp)[4:],))
    uploaded(harness, token, JPEG, "new.jpg")
    assert harness.client.get(f"{API}/attachments/{old['id']}", headers=auth(token)).status_code == 404
    assert len(stored_files(harness)) == 1


# --------------------------------------------------------------------------- provider requests

TURN = ChatTurn(
    role="user",
    content="Compare these",
    attachments=[
        ChatAttachment(kind="image", mime_type="image/png", filename="a.png", data=PNG),
        ChatAttachment(kind="pdf", mime_type="application/pdf", filename="b.pdf", data=PDF),
    ],
)
REQUEST = ChatRequest(model="model-x", turns=[ChatTurn(role="system", content="sys"), TURN])


async def test_openai_sends_input_image_and_input_file_parts() -> None:
    bodies: list[dict[str, Any]] = []

    def handler(request: httpx2.Request) -> httpx2.Response:
        bodies.append(json.loads(request.content))
        return httpx2.Response(500)

    provider = OpenAIProvider(
        api_key="sk-test",
        models=["gpt-6.2-astra", "custom-model"],
        default_model="gpt-6.2-astra",
        max_retries=0,
        http_client=httpx2.AsyncClient(transport=httpx2.MockTransport(handler)),
    )
    [event async for event in provider.stream_chat(REQUEST.model_copy(update={"model": "gpt-6.2-astra"}))]
    [message] = bodies[0]["input"]
    assert message["role"] == "user"
    assert message["content"] == [
        {"type": "input_text", "text": "Compare these"},
        {
            "type": "input_image",
            "image_url": "data:image/png;base64," + base64.b64encode(PNG).decode(),
            "detail": "auto",
        },
        {
            "type": "input_file",
            "filename": "b.pdf",
            "file_data": "data:application/pdf;base64," + base64.b64encode(PDF).decode(),
        },
    ]
    caps = {m.id: m.capabilities for m in provider.list_models()}
    assert caps["gpt-6.2-astra"].image_input and caps["gpt-6.2-astra"].pdf_input
    assert not caps["custom-model"].image_input  # unknown models: text only


async def test_gemini_sends_text_then_inline_data_parts() -> None:
    bodies: list[dict[str, Any]] = []

    def handler(request: httpx2.Request) -> httpx2.Response:
        bodies.append(json.loads(request.content))
        return httpx2.Response(500, json={"error": {"code": 500, "message": "x", "status": "INTERNAL"}})

    provider = GeminiProvider(
        api_key="g-test",
        models=["gemini-4-hydrogen", "custom-gemini"],
        default_model="gemini-4-hydrogen",
        http_client=httpx2.AsyncClient(transport=httpx2.MockTransport(handler)),
    )
    [event async for event in provider.stream_chat(REQUEST.model_copy(update={"model": "gemini-4-hydrogen"}))]
    [content] = bodies[0]["contents"]
    assert content["role"] == "user"
    # As serialised by the official SDK: URL-safe base64 and snake_case nested names,
    # both accepted by protobuf JSON.
    assert content["parts"] == [
        {"text": "Compare these"},
        {"inlineData": {"data": base64.urlsafe_b64encode(PNG).decode(), "mime_type": "image/png"}},
        {"inlineData": {"data": base64.urlsafe_b64encode(PDF).decode(), "mime_type": "application/pdf"}},
    ]
    caps = {m.id: m.capabilities for m in provider.list_models()}
    assert caps["gemini-4-hydrogen"].image_input and caps["gemini-4-hydrogen"].pdf_input
    assert not caps["custom-gemini"].pdf_input

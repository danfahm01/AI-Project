import uuid

from fastapi import FastAPI
from httpx import AsyncClient

from app.models.message import MessageRole
from app.repositories.message_repository import MessageRepository

API = "/api/v1"


async def _conversation(client: AsyncClient, headers: dict[str, str]) -> str:
    return (await client.post(f"{API}/conversations", json={}, headers=headers)).json()["id"]


async def _add_assistant_message(app: FastAPI, conversation_id: str, content: str) -> str:
    """Assistant messages are produced by the AI pipeline (phase 2); insert one directly."""
    async with app.state.db.sessionmaker() as session:
        repo = MessageRepository(session)
        cid = uuid.UUID(conversation_id)
        message = await repo.create(
            conversation_id=cid,
            seq=await repo.next_seq(cid),
            role=MessageRole.ASSISTANT,
            content=content,
            provider="mock",
            model="mock-text",
            input_tokens=3,
            output_tokens=5,
            total_tokens=8,
        )
        await session.commit()
        return str(message.id)


async def test_add_and_list_messages(client: AsyncClient, auth_headers: dict[str, str]) -> None:
    cid = await _conversation(client, auth_headers)
    first = await client.post(
        f"{API}/conversations/{cid}/messages", json={"content": "  keep\n  indentation  "}, headers=auth_headers
    )
    assert first.status_code == 201
    body = first.json()
    assert body["role"] == "user"
    assert body["seq"] == 1
    assert body["status"] == "complete"
    assert body["content"] == "  keep\n  indentation  "  # whitespace preserved
    assert body["usage"] is None

    await client.post(f"{API}/conversations/{cid}/messages", json={"content": "second"}, headers=auth_headers)
    listed = (await client.get(f"{API}/conversations/{cid}/messages", headers=auth_headers)).json()["items"]
    assert [m["seq"] for m in listed] == [1, 2]

    conversation = (await client.get(f"{API}/conversations/{cid}", headers=auth_headers)).json()
    assert conversation["title"] == "keep"  # derived from the first message
    assert conversation["last_message_at"] is not None


async def test_message_metadata_is_exposed(app: FastAPI, client: AsyncClient, auth_headers: dict[str, str]) -> None:
    cid = await _conversation(client, auth_headers)
    await client.post(f"{API}/conversations/{cid}/messages", json={"content": "hi"}, headers=auth_headers)
    await _add_assistant_message(app, cid, "hello")

    assistant = (await client.get(f"{API}/conversations/{cid}/messages", headers=auth_headers)).json()["items"][1]
    assert assistant["role"] == "assistant"
    assert (assistant["provider"], assistant["model"]) == ("mock", "mock-text")
    assert assistant["usage"] == {"input_tokens": 3, "output_tokens": 5, "total_tokens": 8}


async def test_blank_and_oversized_messages_rejected(client: AsyncClient, auth_headers: dict[str, str]) -> None:
    cid = await _conversation(client, auth_headers)
    url = f"{API}/conversations/{cid}/messages"
    assert (await client.post(url, json={"content": "   \n "}, headers=auth_headers)).status_code == 422
    assert (await client.post(url, json={"content": "x" * 32_001}, headers=auth_headers)).status_code == 422
    assert (
        await client.post(url, json={"content": "hi", "role": "assistant"}, headers=auth_headers)
    ).status_code == 422


async def test_editing_user_message_truncates_later_turns(
    app: FastAPI, client: AsyncClient, auth_headers: dict[str, str]
) -> None:
    cid = await _conversation(client, auth_headers)
    url = f"{API}/conversations/{cid}/messages"
    first = (await client.post(url, json={"content": "What is 2+2?"}, headers=auth_headers)).json()
    answer_id = await _add_assistant_message(app, cid, "4")
    follow_up = (await client.post(url, json={"content": "And 3+3?"}, headers=auth_headers)).json()

    response = await client.patch(
        f"{API}/messages/{first['id']}", json={"content": "What is 5+5?"}, headers=auth_headers
    )
    assert response.status_code == 200
    result = response.json()
    assert result["message"]["content"] == "What is 5+5?"
    assert result["message"]["edited_at"] is not None
    assert set(result["removed_message_ids"]) == {answer_id, follow_up["id"]}

    remaining = (await client.get(url, headers=auth_headers)).json()["items"]
    assert [m["id"] for m in remaining] == [first["id"]]

    # New messages continue after the edited one.
    nxt = (await client.post(url, json={"content": "next"}, headers=auth_headers)).json()
    assert nxt["seq"] == 2


async def test_assistant_messages_cannot_be_edited(
    app: FastAPI, client: AsyncClient, auth_headers: dict[str, str]
) -> None:
    cid = await _conversation(client, auth_headers)
    assistant_id = await _add_assistant_message(app, cid, "hello")
    response = await client.patch(f"{API}/messages/{assistant_id}", json={"content": "forged"}, headers=auth_headers)
    assert response.status_code == 403
    assert response.json()["error"]["code"] == "message_not_editable"


async def test_delete_message(client: AsyncClient, auth_headers: dict[str, str]) -> None:
    cid = await _conversation(client, auth_headers)
    message = (
        await client.post(f"{API}/conversations/{cid}/messages", json={"content": "oops"}, headers=auth_headers)
    ).json()
    assert (await client.delete(f"{API}/messages/{message['id']}", headers=auth_headers)).status_code == 204
    assert (await client.delete(f"{API}/messages/{message['id']}", headers=auth_headers)).status_code == 404


async def test_deleting_conversation_cascades_to_messages(
    app: FastAPI, client: AsyncClient, auth_headers: dict[str, str]
) -> None:
    cid = await _conversation(client, auth_headers)
    message = (
        await client.post(f"{API}/conversations/{cid}/messages", json={"content": "bye"}, headers=auth_headers)
    ).json()
    await client.delete(f"{API}/conversations/{cid}", headers=auth_headers)
    async with app.state.db.sessionmaker() as session:
        assert await MessageRepository(session).get_for_user(uuid.UUID(message["id"]), uuid.uuid4()) is None
        from app.models.message import Message

        assert await session.get(Message, uuid.UUID(message["id"])) is None

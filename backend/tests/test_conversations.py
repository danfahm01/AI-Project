import uuid

from httpx import AsyncClient

from app.services.conversation_service import derive_title
from tests.conftest import RegisterFn

API = "/api/v1/conversations"


async def _create(client: AsyncClient, headers: dict[str, str], **body: object) -> dict:
    response = await client.post(API, json=body, headers=headers)
    assert response.status_code == 201, response.text
    return response.json()


async def test_create_get_rename_delete(client: AsyncClient, auth_headers: dict[str, str]) -> None:
    created = await _create(client, auth_headers)
    assert created["title"] == "New conversation"
    assert created["last_message_at"] is None
    assert created["created_at"].endswith(("Z", "+00:00"))  # timezone-aware UTC

    fetched = await client.get(f"{API}/{created['id']}", headers=auth_headers)
    assert fetched.status_code == 200

    renamed = await client.patch(f"{API}/{created['id']}", json={"title": "  Trip plan "}, headers=auth_headers)
    assert renamed.status_code == 200
    assert renamed.json()["title"] == "Trip plan"
    assert renamed.json()["updated_at"] >= created["updated_at"]

    deleted = await client.delete(f"{API}/{created['id']}", headers=auth_headers)
    assert deleted.status_code == 204
    missing = await client.get(f"{API}/{created['id']}", headers=auth_headers)
    assert missing.status_code == 404
    assert missing.json()["error"]["code"] == "conversation_not_found"


async def test_model_selection_per_conversation(client: AsyncClient, auth_headers: dict[str, str]) -> None:
    created = await _create(client, auth_headers, provider="openai", model="some-model")
    assert (created["provider"], created["model"]) == ("openai", "some-model")
    updated = await client.patch(f"{API}/{created['id']}", json={"provider": "gemini"}, headers=auth_headers)
    assert updated.json()["provider"] == "gemini"
    assert updated.json()["model"] == "some-model"


async def test_update_validation(client: AsyncClient, auth_headers: dict[str, str]) -> None:
    created = await _create(client, auth_headers)
    assert (await client.patch(f"{API}/{created['id']}", json={}, headers=auth_headers)).status_code == 422
    assert (await client.patch(f"{API}/{created['id']}", json={"title": None}, headers=auth_headers)).status_code == 422
    bad_provider = await client.patch(f"{API}/{created['id']}", json={"provider": "Bad Name!"}, headers=auth_headers)
    assert bad_provider.status_code == 422


async def test_users_cannot_see_each_others_conversations(client: AsyncClient, register: RegisterFn) -> None:
    alice = {"Authorization": f"Bearer {(await register('alice@example.com'))['tokens']['access_token']}"}
    bob = {"Authorization": f"Bearer {(await register('bob@example.com'))['tokens']['access_token']}"}
    conversation = await _create(client, alice, title="Private")

    for method, url in (
        ("GET", f"{API}/{conversation['id']}"),
        ("PATCH", f"{API}/{conversation['id']}"),
        ("DELETE", f"{API}/{conversation['id']}"),
        ("GET", f"{API}/{conversation['id']}/messages"),
        ("POST", f"{API}/{conversation['id']}/messages"),
    ):
        body = {"title": "x"} if method == "PATCH" else ({"content": "hi"} if method == "POST" else None)
        response = await client.request(method, url, headers=bob, json=body)
        assert response.status_code == 404, (method, url)

    assert (await client.get(API, headers=bob)).json()["items"] == []


async def test_list_orders_by_recent_activity_and_paginates(client: AsyncClient, auth_headers: dict[str, str]) -> None:
    ids = [(await _create(client, auth_headers, title=f"Chat {i}"))["id"] for i in range(5)]
    # Activity on the oldest conversation moves it to the top.
    await client.post(f"{API}/{ids[0]}/messages", json={"content": "bump"}, headers=auth_headers)

    page1 = (await client.get(API, params={"limit": 2}, headers=auth_headers)).json()
    assert [c["id"] for c in page1["items"]] == [ids[0], ids[4]]
    assert page1["next_cursor"]

    page2 = (await client.get(API, params={"limit": 2, "cursor": page1["next_cursor"]}, headers=auth_headers)).json()
    page3 = (await client.get(API, params={"limit": 2, "cursor": page2["next_cursor"]}, headers=auth_headers)).json()
    assert [c["id"] for c in page2["items"]] == [ids[3], ids[2]]
    assert [c["id"] for c in page3["items"]] == [ids[1]]
    assert page3["next_cursor"] is None


async def test_invalid_cursor(client: AsyncClient, auth_headers: dict[str, str]) -> None:
    response = await client.get(API, params={"cursor": "not-a-cursor"}, headers=auth_headers)
    assert response.status_code == 400
    assert response.json()["error"]["code"] == "invalid_cursor"


async def test_search_matches_titles_and_message_text(client: AsyncClient, auth_headers: dict[str, str]) -> None:
    by_title = await _create(client, auth_headers, title="Bali itinerary")
    by_message = await _create(client, auth_headers, title="Misc")
    await client.post(
        f"{API}/{by_message['id']}/messages", json={"content": "Recipe for RENDANG"}, headers=auth_headers
    )
    await _create(client, auth_headers, title="Unrelated")

    def found(q: str):
        return client.get(API, params={"q": q}, headers=auth_headers)

    assert [c["id"] for c in (await found("bali")).json()["items"]] == [by_title["id"]]
    assert [c["id"] for c in (await found("rendang")).json()["items"]] == [by_message["id"]]
    # LIKE wildcards are escaped, so "%" only matches a literal percent sign.
    assert (await found("%")).json()["items"] == []


async def test_unknown_conversation_id_is_404(client: AsyncClient, auth_headers: dict[str, str]) -> None:
    response = await client.get(f"{API}/{uuid.uuid4()}", headers=auth_headers)
    assert response.status_code == 404
    assert (await client.get(f"{API}/not-a-uuid", headers=auth_headers)).status_code == 422


def test_derive_title() -> None:
    assert derive_title("  \n  Hello   world \nsecond line") == "Hello world"
    long = "word " * 30
    title = derive_title(long)
    assert title.endswith("…")
    assert len(title) <= 61
    assert derive_title("   ") == "New conversation"

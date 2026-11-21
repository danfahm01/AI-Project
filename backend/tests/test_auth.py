from datetime import UTC, datetime, timedelta

import jwt
from httpx import AsyncClient

from app.core.config import Settings
from tests.conftest import TEST_PASSWORD, RegisterFn


async def test_register_returns_user_and_tokens(register: RegisterFn) -> None:
    data = await register(email="Ana@Example.COM")
    assert data["user"]["email"] == "ana@example.com"  # normalised
    assert data["user"]["display_name"] == "Ana"
    assert data["tokens"]["token_type"] == "bearer"
    assert data["tokens"]["expires_in"] == 15 * 60
    assert "password" not in str(data["user"]).lower()


async def test_register_duplicate_email_conflicts(client: AsyncClient, register: RegisterFn) -> None:
    await register()
    response = await client.post(
        "/api/v1/auth/register",
        json={"email": "ANA@example.com", "password": TEST_PASSWORD, "display_name": "Other"},
    )
    assert response.status_code == 409
    assert response.json()["error"]["code"] == "email_taken"


async def test_register_validation_never_echoes_password(client: AsyncClient) -> None:
    response = await client.post(
        "/api/v1/auth/register",
        json={"email": "not-an-email", "password": "short7!", "display_name": ""},
    )
    assert response.status_code == 422
    body = response.json()
    assert body["error"]["code"] == "validation_error"
    fields = {tuple(d["loc"]) for d in body["error"]["details"]}
    assert ("body", "email") in fields
    assert ("body", "password") in fields
    assert "short7!" not in response.text


async def test_register_rejects_unknown_fields(client: AsyncClient) -> None:
    response = await client.post(
        "/api/v1/auth/register",
        json={"email": "a@example.com", "password": TEST_PASSWORD, "display_name": "A", "is_admin": True},
    )
    assert response.status_code == 422


async def test_login_success_and_me(client: AsyncClient, register: RegisterFn) -> None:
    await register()
    response = await client.post("/api/v1/auth/login", json={"email": "ana@example.com", "password": TEST_PASSWORD})
    assert response.status_code == 200
    token = response.json()["tokens"]["access_token"]

    me = await client.get("/api/v1/users/me", headers={"Authorization": f"Bearer {token}"})
    assert me.status_code == 200
    assert me.json()["email"] == "ana@example.com"


async def test_login_wrong_password_and_unknown_email_look_identical(client: AsyncClient, register: RegisterFn) -> None:
    await register()
    wrong = await client.post("/api/v1/auth/login", json={"email": "ana@example.com", "password": "nope-nope"})
    unknown = await client.post("/api/v1/auth/login", json={"email": "who@example.com", "password": "nope-nope"})
    assert wrong.status_code == unknown.status_code == 401
    assert wrong.json()["error"]["code"] == unknown.json()["error"]["code"] == "invalid_credentials"
    assert wrong.headers["www-authenticate"] == "Bearer"


async def test_protected_route_requires_token(client: AsyncClient) -> None:
    response = await client.get("/api/v1/users/me")
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "unauthorized"


async def test_tampered_token_rejected(client: AsyncClient, auth_headers: dict[str, str]) -> None:
    token = auth_headers["Authorization"].removeprefix("Bearer ")
    response = await client.get("/api/v1/users/me", headers={"Authorization": f"Bearer {token[:-2]}xx"})
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "invalid_token"


async def test_expired_token_rejected(client: AsyncClient, settings: Settings, register: RegisterFn) -> None:
    data = await register()
    claims = jwt.decode(data["tokens"]["access_token"], options={"verify_signature": False})
    past = datetime.now(UTC) - timedelta(hours=1)
    claims.update(iat=past - timedelta(minutes=15), exp=past)
    expired = jwt.encode(claims, settings.jwt_secret.get_secret_value(), algorithm=settings.jwt_algorithm)

    response = await client.get("/api/v1/users/me", headers={"Authorization": f"Bearer {expired}"})
    assert response.status_code == 401
    assert response.json()["error"]["code"] == "token_expired"


async def test_refresh_rotates_tokens(client: AsyncClient, register: RegisterFn) -> None:
    tokens = (await register())["tokens"]
    response = await client.post("/api/v1/auth/refresh", json={"refresh_token": tokens["refresh_token"]})
    assert response.status_code == 200
    rotated = response.json()
    assert rotated["refresh_token"] != tokens["refresh_token"]

    me = await client.get("/api/v1/users/me", headers={"Authorization": f"Bearer {rotated['access_token']}"})
    assert me.status_code == 200


async def test_refresh_token_reuse_revokes_the_session(client: AsyncClient, register: RegisterFn) -> None:
    original = (await register())["tokens"]["refresh_token"]
    rotated = (await client.post("/api/v1/auth/refresh", json={"refresh_token": original})).json()["refresh_token"]

    replay = await client.post("/api/v1/auth/refresh", json={"refresh_token": original})
    assert replay.status_code == 401
    assert replay.json()["error"]["code"] == "refresh_token_revoked"

    # The legitimate (newer) token is revoked too, since the family is compromised.
    after = await client.post("/api/v1/auth/refresh", json={"refresh_token": rotated})
    assert after.status_code == 401


async def test_logout_revokes_refresh_token(client: AsyncClient, register: RegisterFn) -> None:
    refresh_token = (await register())["tokens"]["refresh_token"]
    response = await client.post("/api/v1/auth/logout", json={"refresh_token": refresh_token})
    assert response.status_code == 204

    response = await client.post("/api/v1/auth/refresh", json={"refresh_token": refresh_token})
    assert response.status_code == 401


async def test_logout_with_unknown_token_is_silent(client: AsyncClient) -> None:
    response = await client.post("/api/v1/auth/logout", json={"refresh_token": "x" * 64})
    assert response.status_code == 204


async def test_update_display_name(client: AsyncClient, auth_headers: dict[str, str]) -> None:
    response = await client.patch("/api/v1/users/me", json={"display_name": "  Ana Maria  "}, headers=auth_headers)
    assert response.status_code == 200
    assert response.json()["display_name"] == "Ana Maria"

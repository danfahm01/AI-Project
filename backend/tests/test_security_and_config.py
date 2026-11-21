import uuid
from pathlib import Path

import pytest
from httpx import AsyncClient
from pydantic import ValidationError

from app.core.config import Settings
from app.core.errors import AuthenticationError
from app.core.security import (
    create_access_token,
    decode_access_token,
    hash_password,
    hash_token,
    verify_password,
)
from tests.conftest import make_settings


def test_password_hashing_uses_argon2id() -> None:
    hashed = hash_password("s3cret-passphrase")
    assert hashed.startswith("$argon2id$")
    assert verify_password(hashed, "s3cret-passphrase")
    assert not verify_password(hashed, "wrong")
    assert not verify_password("not-a-hash", "anything")


def test_access_token_roundtrip(tmp_path: Path) -> None:
    settings = make_settings(tmp_path)
    user_id = uuid.uuid4()
    token, expires_in = create_access_token(user_id, settings)
    assert expires_in == settings.access_token_ttl_minutes * 60
    assert decode_access_token(token, settings) == user_id


def test_token_signed_with_other_secret_rejected(tmp_path: Path) -> None:
    token, _ = create_access_token(uuid.uuid4(), make_settings(tmp_path, jwt_secret="a" * 64))
    with pytest.raises(AuthenticationError):
        decode_access_token(token, make_settings(tmp_path, jwt_secret="b" * 64))


def test_refresh_token_hash_is_stable_and_opaque() -> None:
    assert hash_token("abc") == hash_token("abc")
    assert hash_token("abc") != "abc"
    assert len(hash_token("abc")) == 64


def test_production_requires_strong_secret_and_no_localhost_cors() -> None:
    with pytest.raises(ValidationError, match="JWT_SECRET"):
        Settings(_env_file=None, app_env="production", jwt_secret="short", cors_allow_localhost=False)
    with pytest.raises(ValidationError, match="CORS_ALLOW_LOCALHOST"):
        Settings(_env_file=None, app_env="production", jwt_secret="x" * 64, cors_allow_localhost=True)
    ok = Settings(_env_file=None, app_env="production", jwt_secret="x" * 64, cors_allow_localhost=False)
    assert ok.cors_origin_regex is None


def test_production_requires_https_origins_and_provider_urls() -> None:
    base = {"_env_file": None, "app_env": "production", "jwt_secret": "x" * 64, "cors_allow_localhost": False}
    for origins in ("http://app.example.com", "*", "https://ok.example.com,http://bad.example.com"):
        with pytest.raises(ValidationError, match="CORS_ORIGINS"):
            Settings(**base, cors_origins=origins)
    with pytest.raises(ValidationError, match="OPENAI_BASE_URL"):
        Settings(**base, openai_base_url="http://127.0.0.1:9100/v1")
    with pytest.raises(ValidationError, match="GEMINI_BASE_URL"):
        Settings(**base, gemini_base_url="http://127.0.0.1:9200/")
    ok = Settings(**base, cors_origins="https://app.example.com", openai_base_url="https://gateway.example.com/v1")
    assert ok.cors_origins == ["https://app.example.com"]


async def test_security_headers_on_every_response(client: AsyncClient) -> None:
    for path in ("/health/live", "/api/v1/users/me", "/api/v1/does-not-exist"):
        response = await client.get(path)
        assert response.headers["x-content-type-options"] == "nosniff"
        assert response.headers["x-frame-options"] == "DENY"
        assert response.headers["referrer-policy"] == "no-referrer"
        # Personal data and tokens: never stored by browsers or shared caches.
        assert response.headers["cache-control"] == "no-store"
        assert response.headers["x-request-id"]


async def test_endpoint_cache_headers_are_kept(client: AsyncClient, auth_headers: dict[str, str]) -> None:
    png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 64
    upload = await client.post("/api/v1/attachments", headers=auth_headers, files={"file": ("a.png", png, "image/png")})
    assert upload.status_code == 201, upload.text
    content = await client.get(f"/api/v1/attachments/{upload.json()['id']}/content", headers=auth_headers)
    assert content.headers["cache-control"].startswith("private, max-age=")
    assert content.headers.get_list("x-content-type-options") == ["nosniff"]


def test_development_generates_ephemeral_secret() -> None:
    settings = Settings(_env_file=None, app_env="development", jwt_secret="")
    assert len(settings.jwt_secret.get_secret_value()) >= 64


def test_comma_separated_cors_origins(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("CORS_ORIGINS", "https://app.example.com, https://admin.example.com")
    settings = Settings(_env_file=None)
    assert settings.cors_origins == ["https://app.example.com", "https://admin.example.com"]


def test_blank_api_keys_are_treated_as_unset() -> None:
    settings = Settings(_env_file=None, openai_api_key="", gemini_api_key="  ")
    assert settings.openai_api_key is None
    assert settings.gemini_api_key is None

"""The optional web app served by the API server (WEB_APP_DIR)."""

from collections.abc import AsyncIterator
from pathlib import Path

import pytest
from fastapi import FastAPI
from httpx import ASGITransport, AsyncClient
from starlette.testclient import TestClient
from starlette.websockets import WebSocketDisconnect

from app.main import create_app
from tests.conftest import make_settings


@pytest.fixture
def web_dir(tmp_path: Path) -> Path:
    web = tmp_path / "web"
    (web / "assets" / "fonts").mkdir(parents=True)
    (web / "canvaskit").mkdir()
    (web / "index.html").write_text("<!doctype html><title>app</title>", encoding="utf-8")
    (web / "flutter_bootstrap.js").write_text("// bootstrap", encoding="utf-8")
    (web / "main.dart.a1B2c3_d.js").write_text("// app", encoding="utf-8")
    (web / "assets" / "fonts" / "MaterialIcons.4f2e.otf").write_bytes(b"font")
    (web / "canvaskit" / "canvaskit.wasm").write_bytes(b"\x00asm")
    return web


@pytest.fixture
async def web_app(tmp_path: Path, web_dir: Path) -> AsyncIterator[FastAPI]:
    application = create_app(make_settings(tmp_path, web_app_dir=str(web_dir)))
    async with application.router.lifespan_context(application):
        yield application


@pytest.fixture
async def web_client(web_app: FastAPI) -> AsyncIterator[AsyncClient]:
    async with AsyncClient(transport=ASGITransport(app=web_app), base_url="http://testserver") as http:
        yield http


async def test_index_has_csp_and_is_revalidated(web_client: AsyncClient) -> None:
    response = await web_client.get("/")
    assert response.status_code == 200
    assert response.headers["content-type"].startswith("text/html")
    assert "<title>app</title>" in response.text
    csp = response.headers["content-security-policy"]
    assert "script-src 'self' 'wasm-unsafe-eval'" in csp
    assert "connect-src 'self' https://fonts.gstatic.com https://api.openai.com" in csp
    assert "frame-ancestors 'none'" in csp
    assert response.headers["permissions-policy"].startswith("microphone=(self)")
    assert response.headers["cache-control"] == "no-cache"
    assert response.headers["x-content-type-options"] == "nosniff"


@pytest.mark.parametrize("path", ["/main.dart.a1B2c3_d.js", "/assets/fonts/MaterialIcons.4f2e.otf"])
async def test_content_hashed_files_are_cached_forever(web_client: AsyncClient, path: str) -> None:
    response = await web_client.get(path)
    assert response.status_code == 200
    assert response.headers["cache-control"] == "public, max-age=31536000, immutable"


@pytest.mark.parametrize("path", ["/flutter_bootstrap.js", "/canvaskit/canvaskit.wasm"])
async def test_fixed_names_are_revalidated(web_client: AsyncClient, path: str) -> None:
    response = await web_client.get(path)
    assert response.status_code == 200
    assert response.headers["cache-control"] == "no-cache"
    # Revalidation works: the ETag answers with 304.
    again = await web_client.get(path, headers={"if-none-match": response.headers["etag"]})
    assert again.status_code == 304


async def test_api_routes_win_over_files(web_client: AsyncClient) -> None:
    health = await web_client.get("/health/live")
    assert health.status_code == 200
    assert health.headers["content-type"].startswith("application/json")
    assert health.headers["cache-control"] == "no-store"
    assert "content-security-policy" not in health.headers


@pytest.mark.parametrize("method", ["GET", "POST"])
async def test_unknown_api_path_is_a_json_404(web_client: AsyncClient, method: str) -> None:
    response = await web_client.request(method, "/api/v1/does-not-exist")
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "not_found"


async def test_missing_file_is_404(web_client: AsyncClient) -> None:
    response = await web_client.get("/no-such-file.js")
    assert response.status_code == 404


async def test_files_outside_the_folder_are_not_served(web_client: AsyncClient, tmp_path: Path) -> None:
    (tmp_path / "secret.txt").write_text("secret", encoding="utf-8")
    response = await web_client.get("/..%2Fsecret.txt")
    assert response.status_code == 404
    assert "secret" not in response.text


def test_unknown_websocket_path_is_closed(tmp_path: Path, web_dir: Path) -> None:
    application = create_app(make_settings(tmp_path, web_app_dir=str(web_dir)))
    with (
        TestClient(application) as http,
        pytest.raises(WebSocketDisconnect),
        http.websocket_connect("/not-a-socket") as socket,
    ):
        socket.receive_text()


async def test_without_web_app_dir_root_is_404(client: AsyncClient) -> None:
    response = await client.get("/")
    assert response.status_code == 404
    assert response.json()["error"]["code"] == "not_found"


def test_web_app_dir_without_index_fails_at_startup(tmp_path: Path) -> None:
    empty = tmp_path / "empty"
    empty.mkdir()
    with pytest.raises(RuntimeError, match=r"has no index\.html"):
        create_app(make_settings(tmp_path, web_app_dir=str(empty)))

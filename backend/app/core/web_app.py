"""Serves the Flutter web build from the API server.

Used to run everything as one local server (scripts/start-local.ps1) without
Nginx. Caching and security headers mirror infrastructure/nginx
(app-locations.conf, static-headers.conf) for a build made with

    flutter build web --no-web-resources-cdn --web-content-hash --csp --dart-define=API_BASE_URL=/
"""

import re
from pathlib import Path

from starlette.exceptions import HTTPException
from starlette.responses import Response
from starlette.staticfiles import StaticFiles
from starlette.types import Receive, Scope, Send
from starlette.websockets import WebSocketClose

# --web-content-hash puts a content hash in these names (name.<hash>.ext), so they
# never go stale. The unhashed copies of plugin scripts that
# apps/flutter_app/tool/fixed_name_web_assets.dart adds keep their name and are
# revalidated instead.
_IMMUTABLE = re.compile(r"^(assets/(.+/)?[^/]+\.[0-9a-f]{8,}(\.[^/.]+)?|main\.dart\.[A-Za-z0-9_-]+\.(js|mjs|wasm))$")
# Requests under these prefixes belong to the API: an unknown path there is a JSON
# 404 from the API, never a file lookup.
_API_PREFIXES = ("/api/", "/health/", "/docs", "/redoc", "/openapi.json")


def content_security_policy(connect_src: str) -> str:
    """The policy from static-headers.conf; `connect_src` lists the AI provider
    hosts the browser connects to directly in voice mode."""
    connect = " ".join(filter(None, ["'self'", "https://fonts.gstatic.com", connect_src.strip()]))
    return (
        "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; "
        "style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; "
        "font-src 'self' data: https://fonts.gstatic.com; "
        f"connect-src {connect}; "
        "media-src 'self' blob:; worker-src 'self' blob:; object-src 'none'; "
        "base-uri 'self'; form-action 'self'; frame-ancestors 'none'"
    )


class WebAppFiles(StaticFiles):
    def __init__(self, directory: str | Path, *, connect_src: str) -> None:
        directory = Path(directory)
        if not (directory / "index.html").is_file():
            raise RuntimeError(
                f"WEB_APP_DIR={directory} has no index.html. Build the web app first: "
                "flutter build web --release --no-web-resources-cdn --web-content-hash --csp "
                "--dart-define=API_BASE_URL=/"
            )
        super().__init__(directory=directory, html=True)
        self._csp = content_security_policy(connect_src)

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] == "websocket":
            # No WebSocket route matched this path.
            await WebSocketClose()(scope, receive, send)
            return
        if scope["path"].startswith(_API_PREFIXES):
            raise HTTPException(status_code=404, detail="Not Found")
        await super().__call__(scope, receive, send)

    async def get_response(self, path: str, scope: Scope) -> Response:
        response = await super().get_response(path, scope)
        relative = path.replace("\\", "/").lstrip("./")
        if _IMMUTABLE.match(relative):
            response.headers["cache-control"] = "public, max-age=31536000, immutable"
        else:
            # index.html, flutter_bootstrap.js, canvaskit/: revalidated on every load
            # (ETag), so a rebuilt app is picked up immediately.
            response.headers["cache-control"] = "no-cache"
        response.headers["content-security-policy"] = self._csp
        response.headers["permissions-policy"] = "microphone=(self), camera=(self), geolocation=(), payment=(), usb=()"
        return response

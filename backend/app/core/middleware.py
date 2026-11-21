"""Pure ASGI middleware: request id, security headers, access logging, and
last-resort error handling.

Implemented as raw ASGI (not BaseHTTPMiddleware) so it never buffers streaming
responses, which phase 2 relies on.
"""

import json
import logging
import re
import time
import uuid

from starlette.types import ASGIApp, Message, Receive, Scope, Send

from app.core.errors import error_body
from app.core.logging import request_id_ctx

logger = logging.getLogger("app.access")

_VALID_REQUEST_ID = re.compile(r"^[A-Za-z0-9\-]{8,64}$")

# Sent on every response unless the endpoint set its own value. API responses
# carry personal data and tokens, so nothing is cached by default (endpoints that
# can be cached, such as attachment content, set their own Cache-Control).
_DEFAULT_HEADERS: tuple[tuple[bytes, bytes], ...] = (
    (b"x-content-type-options", b"nosniff"),
    (b"x-frame-options", b"DENY"),
    (b"referrer-policy", b"no-referrer"),
    (b"cache-control", b"no-store"),
)


def _with_defaults(headers: list[tuple[bytes, bytes]]) -> list[tuple[bytes, bytes]]:
    present = {name.lower() for name, _ in headers}
    return headers + [(name, value) for name, value in _DEFAULT_HEADERS if name not in present]


class RequestContextMiddleware:
    def __init__(self, app: ASGIApp) -> None:
        self.app = app

    async def __call__(self, scope: Scope, receive: Receive, send: Send) -> None:
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return

        incoming = dict(scope.get("headers") or []).get(b"x-request-id", b"").decode("latin-1")
        request_id = incoming if _VALID_REQUEST_ID.match(incoming) else uuid.uuid4().hex
        token = request_id_ctx.set(request_id)

        started = time.perf_counter()
        status_code = 500
        response_started = False

        async def send_wrapper(message: Message) -> None:
            nonlocal status_code, response_started
            if message["type"] == "http.response.start":
                response_started = True
                status_code = message["status"]
                headers = _with_defaults(list(message.get("headers", [])))
                headers.append((b"x-request-id", request_id.encode("latin-1")))
                message["headers"] = headers
            await send(message)

        try:
            await self.app(scope, receive, send_wrapper)
        except Exception:
            logger.exception("Unhandled error while processing %s %s", scope["method"], scope["path"])
            if not response_started:
                body = json.dumps(error_body("internal_error", "An unexpected error occurred")).encode()
                await send_wrapper(
                    {
                        "type": "http.response.start",
                        "status": 500,
                        "headers": [
                            (b"content-type", b"application/json"),
                            (b"content-length", str(len(body)).encode()),
                        ],
                    }
                )
                await send({"type": "http.response.body", "body": body})
        finally:
            elapsed_ms = (time.perf_counter() - started) * 1000
            logger.info("%s %s -> %d (%.1f ms)", scope["method"], scope["path"], status_code, elapsed_ms)
            request_id_ctx.reset(token)

"""Smoke test for a running deployment (local, Docker, staging or production).

Checks health, security and caching headers, sign-up and sign-in, conversations,
attachments and the chat WebSocket against a live server, then deletes what it
created. It uses a throwaway account (a random address at example.com) unless
--email is given; that account is left in place, because the API has no account
deletion yet.

    python scripts/smoke_test.py --base-url http://localhost:8000
    python scripts/smoke_test.py --base-url https://assistant.example.com --web
    python scripts/smoke_test.py --base-url https://localhost --insecure --web --chat --check-rate-limit

Options with side effects:
  --chat              sends one chat message. With a provider key configured this
                      is a real (billed) model request; without one, the expected
                      answer is "no AI provider is configured".
  --check-rate-limit  makes failed sign-ins with forged X-Forwarded-For headers
                      until the auth limit triggers. Sign-ins from this machine are
                      then blocked for up to a minute. Run it against the Nginx
                      edge: uvicorn trusts proxy headers from 127.0.0.1 by
                      default, so a direct local connection is expected to fail it.

To reuse an existing test account, pass --email and set SMOKE_TEST_PASSWORD.
Exit code 0 when every check passed, 1 otherwise.
"""

import argparse
import asyncio
import json
import os
import re
import secrets
import ssl
import sys
import uuid
from typing import Any

import httpx
from websockets.asyncio.client import connect

# A minimal PNG header: enough for the server's type detection.
PNG = b"\x89PNG\r\n\x1a\n" + b"\x00\x00\x00\rIHDR" + bytes(80)
TERMINAL_EVENTS = {"response.completed", "response.failed", "response.cancelled"}


class Report:
    def __init__(self) -> None:
        self.failures: list[str] = []
        self.passed = 0

    def check(self, name: str, ok: bool, detail: Any = "") -> bool:
        if ok:
            self.passed += 1
            print(f"PASS  {name}")
        else:
            self.failures.append(name)
            print(f"FAIL  {name}: {str(detail)[:300]}")
        return ok


def _header_check(report: Report, label: str, response: httpx.Response, name: str, expected: str) -> None:
    value = response.headers.get(name, "")
    report.check(f"{label}: {name}", expected in value, f"got {value!r}")


async def check_web_app(report: Report, http: httpx.AsyncClient, base: str) -> None:
    index = await http.get(f"{base}/")
    report.check(
        "web: index.html", index.status_code == 200 and "flutter_bootstrap.js" in index.text, index.status_code
    )
    _header_check(report, "web", index, "content-security-policy", "default-src 'self'")
    _header_check(report, "web", index, "cache-control", "no-cache")
    if base.startswith("https://"):
        _header_check(report, "web", index, "strict-transport-security", "max-age=")

    bootstrap = await http.get(f"{base}/flutter_bootstrap.js")
    match = re.search(r"main\.dart\.[A-Za-z0-9_-]+\.js", bootstrap.text)
    if not report.check("web: content-hashed entrypoint", match is not None, "no main.dart.<hash>.js"):
        return
    assert match is not None
    entry = await http.get(f"{base}/{match.group(0)}", headers={"Accept-Encoding": "gzip"})
    report.check("web: entrypoint served", entry.status_code == 200, entry.status_code)
    _header_check(report, "web entrypoint", entry, "cache-control", "immutable")
    _header_check(report, "web entrypoint", entry, "content-encoding", "gzip")

    # Voice mode: plugins load these by a fixed name (tool/fixed_name_web_assets.dart).
    for label, path in (
        ("microphone worklet", "assets/packages/record_web/assets/js/record.worklet.js"),
        ("audio player script", "assets/packages/mp_audio_stream/js/audio_stream.js"),
    ):
        script = await http.get(f"{base}/{path}")
        report.check(f"web: {label}", script.status_code == 200, script.status_code)
        _header_check(report, f"web {label}", script, "content-type", "javascript")
        _header_check(report, f"web {label}", script, "cache-control", "no-cache")


async def check_http_redirect(report: Report, http: httpx.AsyncClient, http_url: str) -> None:
    response = await http.get(f"{http_url.rstrip('/')}/api/v1/providers")
    location = response.headers.get("location", "")
    report.check("http: redirects to https", response.status_code == 301 and location.startswith("https://"), location)


async def check_chat_socket(
    report: Report, base: str, token: str, conversation_id: str, *, chat: bool, insecure: bool
) -> None:
    ws_url = re.sub(r"^http", "ws", base) + "/api/v1/chat/ws"
    context: ssl.SSLContext | None = None
    if ws_url.startswith("wss://"):
        context = ssl.create_default_context()
        if insecure:
            context.check_hostname = False
            context.verify_mode = ssl.CERT_NONE
    async with connect(ws_url, ssl=context, open_timeout=15) as ws:
        await ws.send(json.dumps({"type": "auth", "token": token}))
        auth = json.loads(await asyncio.wait_for(ws.recv(), 15))
        if not report.check("ws: authenticated", auth.get("type") == "auth.ok", auth):
            return
        await ws.send(json.dumps({"type": "ping"}))
        pong = json.loads(await asyncio.wait_for(ws.recv(), 15))
        report.check("ws: ping/pong", pong == {"type": "pong"}, pong)
        if not chat:
            return

        await ws.send(
            json.dumps(
                {
                    "type": "message.send",
                    "request_id": "smoke-1",
                    "conversation_id": conversation_id,
                    "content": "Reply with the single word: pong",
                }
            )
        )
        events: list[dict[str, Any]] = []
        while not events or events[-1]["type"] not in TERMINAL_EVENTS:
            events.append(json.loads(await asyncio.wait_for(ws.recv(), 180)))
        types = [e["type"] for e in events]
        report.check("ws: message stored", "message.created" in types, types)
        final = events[-1]
        if final["type"] == "response.completed":
            report.check("ws: reply streamed", bool(final["message"]["content"].strip()), final)
        else:
            code = (final.get("error") or {}).get("code")
            # A server without provider keys answers like this; anything else is a failure.
            report.check(f"ws: reply ({code})", code == "provider_not_available", json.dumps(final.get("error")))


async def check_rate_limit(report: Report, http: httpx.AsyncClient, api: str) -> None:
    statuses = []
    for attempt in range(40):
        # A different forged client address every time: the edge must ignore it.
        forged = f"203.0.113.{attempt + 1}"
        response = await http.post(
            f"{api}/auth/login",
            json={"email": f"nobody-{uuid.uuid4().hex[:8]}@example.com", "password": "wrong-password"},
            headers={"X-Forwarded-For": forged},
        )
        statuses.append(response.status_code)
        if response.status_code == 429:
            break
    report.check("auth rate limit ignores forged X-Forwarded-For", 429 in statuses, statuses)


async def run(args: argparse.Namespace) -> int:
    base = args.base_url.rstrip("/")
    api = f"{base}/api/v1"
    report = Report()
    # --insecure is for self-signed test certificates only (local Docker, CI).
    async with httpx.AsyncClient(verify=not args.insecure, timeout=30) as http:
        health = await http.get(f"{base}/health/ready")
        report.check("health: ready", health.status_code == 200, f"{health.status_code} {health.text}")
        _header_check(report, "api", health, "x-content-type-options", "nosniff")
        _header_check(report, "api", health, "cache-control", "no-store")
        if base.startswith("https://"):
            _header_check(report, "api", health, "strict-transport-security", "max-age=")

        if args.web:
            await check_web_app(report, http, base)
        if args.http_url:
            await check_http_redirect(report, http, args.http_url)

        email = args.email or f"smoke-{uuid.uuid4().hex[:12]}@example.com"
        password = os.environ.get("SMOKE_TEST_PASSWORD") if args.email else secrets.token_urlsafe(18)
        if not password:
            print("Set SMOKE_TEST_PASSWORD for --email", file=sys.stderr)
            return 2
        if not args.email:
            registered = await http.post(
                f"{api}/auth/register", json={"email": email, "password": password, "display_name": "Smoke test"}
            )
            report.check("auth: register", registered.status_code == 201, registered.text)
        login = await http.post(f"{api}/auth/login", json={"email": email, "password": password})
        if not report.check("auth: login", login.status_code == 200, login.text):
            return 1
        _header_check(report, "auth", login, "cache-control", "no-store")
        tokens = login.json()["tokens"]
        auth = {"Authorization": f"Bearer {tokens['access_token']}"}

        me = await http.get(f"{api}/users/me", headers=auth)
        report.check("users: me", me.status_code == 200 and me.json().get("email") == email, me.text)
        providers = await http.get(f"{api}/providers", headers=auth)
        report.check("providers: listed", providers.status_code == 200, providers.text)

        created = await http.post(f"{api}/conversations", json={"title": "Smoke test"}, headers=auth)
        if not report.check("conversations: create", created.status_code == 201, created.text):
            return 1
        conversation_id = created.json()["id"]
        try:
            renamed = await http.patch(
                f"{api}/conversations/{conversation_id}", json={"title": "Smoke test (renamed)"}, headers=auth
            )
            report.check("conversations: rename", renamed.status_code == 200, renamed.text)

            upload = await http.post(
                f"{api}/attachments", files={"file": ("smoke.png", PNG, "image/png")}, headers=auth
            )
            if report.check("attachments: upload", upload.status_code == 201, upload.text):
                attachment_id = upload.json()["id"]
                content = await http.get(f"{api}/attachments/{attachment_id}/content", headers=auth)
                report.check("attachments: content", content.content == PNG, content.status_code)
                link = await http.post(f"{api}/attachments/{attachment_id}/link", headers=auth)
                if report.check("attachments: signed link", link.status_code == 200, link.text):
                    download = await http.get(f"{api}{link.json()['path']}")
                    report.check("attachments: signed download", download.content == PNG, download.status_code)
                unauthenticated = await http.get(f"{api}/attachments/{attachment_id}/content")
                report.check(
                    "attachments: auth required", unauthenticated.status_code == 401, unauthenticated.status_code
                )
                deleted = await http.delete(f"{api}/attachments/{attachment_id}", headers=auth)
                report.check("attachments: delete", deleted.status_code == 204, deleted.text)

            try:
                await check_chat_socket(
                    report, base, tokens["access_token"], conversation_id, chat=args.chat, insecure=args.insecure
                )
            except (OSError, TimeoutError) as exc:
                report.check("ws: connect", False, repr(exc))
        finally:
            removed = await http.delete(f"{api}/conversations/{conversation_id}", headers=auth)
            report.check("conversations: delete", removed.status_code == 204, removed.text)

        logout = await http.post(f"{api}/auth/logout", json={"refresh_token": tokens["refresh_token"]})
        report.check("auth: logout", logout.status_code == 204, logout.text)

        if args.check_rate_limit:
            await check_rate_limit(report, http, api)

    print(f"\n{report.passed} passed, {len(report.failures)} failed")
    for name in report.failures:
        print(f"  failed: {name}")
    return 1 if report.failures else 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--base-url", required=True, help="Server origin, e.g. https://assistant.example.com")
    parser.add_argument("--web", action="store_true", help="Also check the web app served at the base URL")
    parser.add_argument("--http-url", help="Plain-HTTP origin that must redirect to HTTPS, e.g. http://localhost")
    parser.add_argument("--chat", action="store_true", help="Send one chat message (billed with a provider key)")
    parser.add_argument("--check-rate-limit", action="store_true", help="Verify the auth rate limit (blocks sign-ins)")
    parser.add_argument("--email", help="Existing test account (password from SMOKE_TEST_PASSWORD)")
    parser.add_argument("--insecure", action="store_true", help="Accept self-signed TLS certificates (testing only)")
    sys.exit(asyncio.run(run(parser.parse_args())))


if __name__ == "__main__":
    main()

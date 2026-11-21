"""Local stand-in for a few Gemini API endpoints, for manual end-to-end testing
of the real Gemini adapter without an API key or credits.

* ``POST /v1beta/models/{model}:streamGenerateContent?alt=sse`` streams
  ``GenerateContentResponse`` chunks like the real API; replies say they are test output.
* ``POST /v1beta/auth_tokens`` returns a fake ephemeral token for the Live API.
* ``WS /ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained``
  accepts that token, answers ``setup`` with ``setupComplete`` and answers each
  finished user turn with a short silent audio chunk, a transcript that says it
  comes from a test server, and ``turnComplete``. It does not understand speech.

    python -m tests.fakes.fake_gemini_server --port 9200
    # then run the backend with:
    GEMINI_API_KEY=local-test GEMINI_BASE_URL=http://127.0.0.1:9200/

Never point a production deployment at this server.
"""

import argparse
import asyncio
import base64
import json
import re
import secrets
from collections.abc import AsyncIterator
from datetime import UTC, datetime, timedelta
from typing import Any

import uvicorn
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.middleware.cors import CORSMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, StreamingResponse
from starlette.routing import Route, WebSocketRoute
from starlette.websockets import WebSocket, WebSocketDisconnect

REPLY = """*Local Gemini test server — this is not a real model.* You asked: "{question}"

- A list item with `inline code`
- Model: **{model}**

```dart
void main() => print('Hello from the test server');
```
"""

VOICE_REPLY = "This reply comes from a local test server, not from Gemini."
LIVE_PATH = "/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContentConstrained"

_tokens: dict[str, datetime] = {}


def _error(status: int, message: str, code: str) -> JSONResponse:
    return JSONResponse({"error": {"code": status, "message": message, "status": code}}, status_code=status)


async def stream_generate_content(request: Request) -> StreamingResponse | JSONResponse:
    model = request.path_params["model"]
    body = await request.json()
    contents = body.get("contents") or []
    if not contents:
        return _error(400, "contents is required", "INVALID_ARGUMENT")
    question = ""
    files: list[str] = []
    for content in reversed(contents):
        if content.get("role") == "user":
            parts = content.get("parts", [])
            question = "".join(part.get("text", "") for part in parts)
            for part in parts:
                inline = part.get("inlineData") or part.get("inline_data") or {}
                mime = inline.get("mimeType") or inline.get("mime_type")
                if mime and inline.get("data"):
                    files.append(mime)
            break
    reply = REPLY.format(question=question[:80].replace('"', "'"), model=model)
    if files:
        reply += "\n\nAttachments received: " + ", ".join(files) + "."

    async def chunks() -> AsyncIterator[bytes]:
        pieces = re.findall(r"\S+\s*", reply)
        for index, piece in enumerate(pieces):
            await asyncio.sleep(0.04)
            chunk: dict[str, Any] = {
                "candidates": [{"content": {"role": "model", "parts": [{"text": piece}]}, "index": 0}],
                "modelVersion": model,
                "responseId": "local-response",
            }
            if index == len(pieces) - 1:
                chunk["candidates"][0]["finishReason"] = "STOP"
                chunk["usageMetadata"] = {
                    "promptTokenCount": 21,
                    "candidatesTokenCount": len(pieces),
                    "totalTokenCount": 21 + len(pieces),
                }
            yield f"data: {json.dumps(chunk)}\r\n\r\n".encode()

    return StreamingResponse(chunks(), media_type="text/event-stream")


async def auth_tokens(request: Request) -> JSONResponse:
    body = await request.json()
    setup = body.get("bidiGenerateContentSetup") or {}
    if not setup.get("model"):
        return _error(400, "bidiGenerateContentSetup.model is required", "INVALID_ARGUMENT")
    expire = body.get("expireTime") or (datetime.now(UTC) + timedelta(minutes=30)).isoformat()
    name = f"auth_tokens/local-test-{secrets.token_hex(8)}"
    _tokens[name] = datetime.fromisoformat(expire.replace("Z", "+00:00"))
    return JSONResponse(
        {
            "name": name,
            "expireTime": expire,
            "newSessionExpireTime": body.get("newSessionExpireTime"),
            "uses": body.get("uses", 1),
        }
    )


async def _send(websocket: WebSocket, message: dict[str, Any]) -> None:
    # The real service sends JSON in binary frames.
    await websocket.send_bytes(json.dumps(message).encode())


async def live(websocket: WebSocket) -> None:
    token = websocket.query_params.get("access_token", "")
    expires = _tokens.get(token)
    if expires is None or expires < datetime.now(UTC):
        await websocket.close(code=1008, reason="Invalid or expired access token")
        return
    await websocket.accept()
    try:
        first = json.loads(await websocket.receive_text())
        if "setup" not in first:
            await websocket.close(code=1007, reason="The first message must be setup")
            return
        await _send(websocket, {"setupComplete": {}})
        await _send(websocket, {"sessionResumptionUpdate": {"newHandle": "local-handle-1", "resumable": True}})
        audio_bytes = 0
        while True:
            message = json.loads(await websocket.receive_text())
            realtime = message.get("realtimeInput") or {}
            if "audio" in realtime:
                audio_bytes += len(base64.b64decode(realtime["audio"].get("data", "")))
            finished = "activityEnd" in realtime or "audioStreamEnd" in realtime or "text" in realtime
            if not finished:
                continue
            await _send(
                websocket,
                {"serverContent": {"inputTranscription": {"text": f"({audio_bytes} bytes of audio received)"}}},
            )
            audio_bytes = 0
            silence = base64.b64encode(bytes(24_000 * 2 // 5)).decode()  # 200 ms at 24 kHz
            await _send(
                websocket,
                {
                    "serverContent": {
                        "modelTurn": {"parts": [{"inlineData": {"mimeType": "audio/pcm;rate=24000", "data": silence}}]},
                        "outputTranscription": {"text": VOICE_REPLY},
                    }
                },
            )
            await _send(websocket, {"serverContent": {"generationComplete": True}})
            await _send(websocket, {"serverContent": {"turnComplete": True}})
    except WebSocketDisconnect:
        return


app = Starlette(
    routes=[
        Route("/v1beta/models/{model}:streamGenerateContent", stream_generate_content, methods=["POST"]),
        Route("/v1beta/auth_tokens", auth_tokens, methods=["POST"]),
        WebSocketRoute(LIVE_PATH, live),
    ],
    middleware=[Middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["POST"], allow_headers=["*"])],
)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=9200)
    uvicorn.run(app, host="127.0.0.1", port=parser.parse_args().port)

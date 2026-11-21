"""Local stand-in for a few OpenAI endpoints, for manual end-to-end testing
of the real OpenAI adapter without an API key or credits.

* ``POST /v1/responses`` streams the documented event sequence (official SDK,
  SSE parsing, WebSocket relay, Markdown rendering); replies say they are test output.
* ``POST /v1/realtime/client_secrets`` returns a fake ephemeral key, so voice
  session minting can be exercised.
* ``POST /v1/realtime/calls`` answers 501: real voice audio needs the real API.

    python -m tests.fakes.fake_openai_server --port 9100
    # then run the backend with:
    OPENAI_API_KEY=local-test OPENAI_BASE_URL=http://127.0.0.1:9100/v1

Never point a production deployment at this server.
"""

import argparse
import asyncio
import json
import re
import secrets
import time
from collections.abc import AsyncIterator
from typing import Any

import uvicorn
from starlette.applications import Starlette
from starlette.middleware import Middleware
from starlette.middleware.cors import CORSMiddleware
from starlette.requests import Request
from starlette.responses import JSONResponse, StreamingResponse
from starlette.routing import Route

REPLY = """*Local test server — this is not a real model.* You asked: "{question}"

Here is a **Markdown** sample so the client rendering can be checked:

1. A numbered item with `inline code`
2. A [link](https://developers.openai.com/api/docs/models)

```python
def greet(name: str) -> str:
    return f"Hello, {{name}}!"
```

| Model ID | Tier |
| --- | --- |
| gpt-6.2-astra | Flagship |
| gpt-6-luna | Cost-efficient |
"""


def _sse(event: dict[str, Any]) -> bytes:
    return f"event: {event['type']}\ndata: {json.dumps(event)}\n\n".encode()


def _describe_user_turn(content: Any) -> tuple[str, str]:
    """(text, attachment summary) of a user input message: a string, or content
    parts (``input_text`` / ``input_image`` / ``input_file``)."""
    if isinstance(content, str):
        return content, ""
    text = " ".join(p.get("text", "") for p in content if p.get("type") == "input_text")
    images = sum(1 for p in content if p.get("type") == "input_image" and str(p.get("image_url")).startswith("data:"))
    files = [p.get("filename", "?") for p in content if p.get("type") == "input_file" and p.get("file_data")]
    parts = [f"{images} image(s)"] if images else []
    parts += [f"file {name}" for name in files]
    return text, ("\n\nAttachments received: " + ", ".join(parts) + ".") if parts else ""


async def responses(request: Request) -> StreamingResponse:
    body = await request.json()
    content = next((m.get("content", "") for m in reversed(body.get("input", [])) if m.get("role") == "user"), "")
    question, attachments = _describe_user_turn(content)
    reply = REPLY.format(question=str(question)[:80].replace('"', "'")) + attachments
    model = body.get("model", "unknown")

    async def events() -> AsyncIterator[bytes]:
        seq = 0
        yield _sse(
            {
                "type": "response.created",
                "sequence_number": seq,
                "response": {"id": "resp_local", "status": "in_progress", "model": model},
            }
        )
        for chunk in re.findall(r"\S+\s*", reply):
            seq += 1
            await asyncio.sleep(0.04)
            yield _sse(
                {
                    "type": "response.output_text.delta",
                    "sequence_number": seq,
                    "item_id": "msg_local",
                    "output_index": 0,
                    "content_index": 0,
                    "delta": chunk,
                    "logprobs": [],
                }
            )
        words = len(reply.split())
        yield _sse(
            {
                "type": "response.completed",
                "sequence_number": seq + 1,
                "response": {
                    "id": "resp_local",
                    "object": "response",
                    "status": "completed",
                    "model": model,
                    "output": [],
                    "usage": {"input_tokens": 42, "output_tokens": words, "total_tokens": 42 + words},
                },
            }
        )

    return StreamingResponse(events(), media_type="text/event-stream")


async def client_secrets(request: Request) -> JSONResponse:
    """``POST /v1/realtime/client_secrets``: echoes the session with a fake ephemeral key."""
    body = await request.json()
    session = body.get("session") or {}
    if session.get("type") != "realtime" or not session.get("model"):
        return JSONResponse(
            {
                "error": {
                    "message": "session.type 'realtime' and session.model are required",
                    "type": "invalid_request_error",
                }
            },
            status_code=400,
        )
    ttl = int((body.get("expires_after") or {}).get("seconds", 600))
    return JSONResponse(
        {"value": f"ek_local_test_{secrets.token_hex(8)}", "expires_at": int(time.time()) + ttl, "session": session}
    )


async def realtime_calls(request: Request) -> JSONResponse:
    """``POST /v1/realtime/calls``: a local stand-in cannot negotiate WebRTC audio."""
    return JSONResponse(
        {"error": {"message": "The local test server cannot run WebRTC voice calls.", "type": "not_implemented"}},
        status_code=501,
    )


app = Starlette(
    routes=[
        Route("/v1/responses", responses, methods=["POST"]),
        Route("/v1/realtime/client_secrets", client_secrets, methods=["POST"]),
        Route("/v1/realtime/calls", realtime_calls, methods=["POST"]),
    ],
    # Browsers post the SDP offer directly, as they do to the real API.
    middleware=[Middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["POST"], allow_headers=["*"])],
)

if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=9100)
    uvicorn.run(app, host="127.0.0.1", port=parser.parse_args().port)

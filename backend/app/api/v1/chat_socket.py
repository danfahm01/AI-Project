"""WebSocket endpoint for streaming chat: ``/api/v1/chat/ws``.

Authentication: browsers cannot set headers on WebSockets, and tokens in URLs
end up in logs, so the client's first frame must be
``{"type": "auth", "token": "<access token>"}`` (within 10 s).

A generation keeps running if the client disconnects, so a reply is never lost
on a flaky network; the client reloads the conversation after reconnecting.
"""

import asyncio
import contextlib
import logging
import uuid
from typing import Any

from fastapi import APIRouter, WebSocket, WebSocketDisconnect
from pydantic import ValidationError

from app.core.errors import AuthenticationError
from app.core.security import decode_access_token
from app.models.user import User
from app.schemas.chat_socket import (
    AuthCommand,
    CancelCommand,
    PingCommand,
    RegenerateCommand,
    SendMessageCommand,
    client_command_adapter,
)
from app.services.chat_service import ChatService

logger = logging.getLogger(__name__)
router = APIRouter()

AUTH_TIMEOUT_SECONDS = 10
CLOSE_UNAUTHORIZED = 4401


class ChatConnection:
    def __init__(self, websocket: WebSocket, user: User) -> None:
        self.websocket = websocket
        self.user = user
        self.app_state = websocket.app.state
        self._send_lock = asyncio.Lock()
        self._closed = False
        self._active: tuple[str, asyncio.Task[None]] | None = None

    async def emit(self, payload: dict[str, Any]) -> None:
        if self._closed:
            return
        try:
            async with self._send_lock:
                await self.websocket.send_json(payload)
        except (WebSocketDisconnect, RuntimeError, OSError):
            self._closed = True

    async def error(self, code: str, message: str, request_id: str | None = None) -> None:
        await self.emit({"type": "error", "request_id": request_id, "error": {"code": code, "message": message}})

    async def run(self) -> None:
        try:
            while True:
                try:
                    raw = await self.websocket.receive_json()
                except (ValueError, KeyError):
                    await self.error("invalid_command", "Frames must be JSON objects")
                    continue
                await self._handle(raw)
        except WebSocketDisconnect:
            pass
        finally:
            self._closed = True

    async def _handle(self, raw: Any) -> None:
        try:
            command = client_command_adapter.validate_python(raw)
        except ValidationError as exc:
            details = "; ".join(f"{'.'.join(map(str, e['loc']))}: {e['msg']}" for e in exc.errors()[:3])
            request_id = raw.get("request_id") if isinstance(raw, dict) else None
            await self.error(
                "invalid_command", details or "Invalid command", request_id if isinstance(request_id, str) else None
            )
            return

        match command:
            case PingCommand():
                await self.emit({"type": "pong"})
            case AuthCommand():
                await self.error("already_authenticated", "This connection is already authenticated")
            case CancelCommand(request_id=request_id):
                if self._active is not None and self._active[0] == request_id:
                    self._active[1].cancel()
            case SendMessageCommand() | RegenerateCommand():
                await self._start(command)

    async def _start(self, command: SendMessageCommand | RegenerateCommand) -> None:
        if self._active is not None and not self._active[1].done():
            await self.error("busy", "Wait for the current response to finish or cancel it", command.request_id)
            return

        settings = self.app_state.settings
        limit = await self.app_state.rate_limiter.hit(f"chat:{self.user.id}", settings.rate_limit_chat_per_minute, 60)
        if not limit.allowed:
            await self.error(
                "rate_limited", f"Too many messages. Try again in {limit.reset_after} s.", command.request_id
            )
            return

        service = ChatService(
            self.app_state.db.sessionmaker, self.app_state.providers, settings, self.app_state.attachment_storage
        )
        is_send = isinstance(command, SendMessageCommand)
        task = asyncio.create_task(
            service.generate(
                user=self.user,
                conversation_id=command.conversation_id,
                request_id=command.request_id,
                content=command.content if is_send else None,
                attachment_ids=command.attachment_ids if is_send else [],
                emit=self.emit,
            ),
            name=f"chat-generation-{command.request_id}",
        )
        # Keep a strong reference until done; generations outlive the connection.
        background: set[asyncio.Task[None]] = self.app_state.background_tasks
        background.add(task)
        task.add_done_callback(background.discard)
        task.add_done_callback(_log_task_failure)
        self._active = (command.request_id, task)


def _log_task_failure(task: asyncio.Task[None]) -> None:
    if not task.cancelled() and task.exception() is not None:
        logger.error("Chat generation crashed", exc_info=task.exception())


async def _authenticate(websocket: WebSocket) -> User | None:
    try:
        raw = await asyncio.wait_for(websocket.receive_json(), timeout=AUTH_TIMEOUT_SECONDS)
        command = client_command_adapter.validate_python(raw)
    except (TimeoutError, ValueError, ValidationError, KeyError):
        await _reject(websocket, "unauthorized", 'Send {"type": "auth", "token": ...} first')
        return None
    except WebSocketDisconnect:
        return None
    if not isinstance(command, AuthCommand):
        await _reject(websocket, "unauthorized", "Authenticate before sending commands")
        return None

    try:
        user_id: uuid.UUID = decode_access_token(command.token, websocket.app.state.settings)
    except AuthenticationError as exc:
        await _reject(websocket, exc.code, exc.message)
        return None

    async with websocket.app.state.db.sessionmaker() as session:
        user = await session.get(User, user_id)
    if user is None or not user.is_active:
        await _reject(websocket, "invalid_token", "Account not found or disabled")
        return None
    return user


async def _reject(websocket: WebSocket, code: str, message: str) -> None:
    with contextlib.suppress(WebSocketDisconnect, RuntimeError, OSError):
        await websocket.send_json({"type": "auth.failed", "error": {"code": code, "message": message}})
        await websocket.close(code=CLOSE_UNAUTHORIZED, reason=code)


@router.websocket("/chat/ws")
async def chat_socket(websocket: WebSocket) -> None:
    await websocket.accept()
    user = await _authenticate(websocket)
    if user is None:
        return
    await websocket.send_json({"type": "auth.ok", "user_id": str(user.id)})
    await ChatConnection(websocket, user).run()

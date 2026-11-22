"""AI response generation for a conversation, streamed through an ``emit`` callback.

One generation:
1. (DB) resolve provider/model; check the attachments against it; store the user
   message (linking its attachments), or drop the last assistant reply when
   regenerating; create the assistant message with status ``streaming``.
2. (no DB session held) stream the provider's deltas to the client.
3. (DB) persist the final text, status (complete / error / cancelled), usage and metadata.

Events emitted (all carry ``request_id`` and ``conversation_id``):
``message.created``, ``message.deleted``, ``conversation.updated``,
``response.started``, ``response.delta``, ``response.completed``,
``response.cancelled``, ``response.failed``.
"""

import asyncio
import hashlib
import logging
import uuid
from collections.abc import Awaitable, Callable, Collection, Sequence
from dataclasses import dataclass, field
from typing import Any

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker

from app.ai_providers.base import (
    AIProvider,
    ChatAttachment,
    ChatRequest,
    ChatTurn,
    ChatUsage,
    ModelInfo,
    ProviderError,
)
from app.ai_providers.registry import ProviderNotAvailableError, ProviderRegistry
from app.core.config import Settings
from app.core.errors import AppError
from app.db.base import utcnow
from app.models.attachment import ConversationAttachment
from app.models.conversation import DEFAULT_CONVERSATION_TITLE, Conversation
from app.models.message import Message, MessageRole, MessageStatus
from app.models.user import User
from app.repositories.conversation_repository import ConversationRepository
from app.repositories.message_repository import MessageRepository
from app.repositories.preferences_repository import PreferencesRepository
from app.schemas.conversation import ConversationOut
from app.schemas.message import MessageOut
from app.services.attachment_service import AttachmentService, kind_supported
from app.services.attachment_storage import AttachmentStorage
from app.services.conversation_service import derive_title

logger = logging.getLogger(__name__)

Emit = Callable[[dict[str, Any]], Awaitable[None]]


@dataclass
class _Generation:
    request_id: str
    conversation_id: uuid.UUID
    message_id: uuid.UUID
    provider: AIProvider
    model: ModelInfo
    request: ChatRequest
    text: list[str] = field(default_factory=list)
    usage: ChatUsage | None = None
    metadata: dict[str, Any] = field(default_factory=dict)


def end_user_id(user_id: uuid.UUID) -> str:
    """Stable pseudonymous ID for provider abuse monitoring (no email or name)."""
    return hashlib.sha256(f"voice-assistant:{user_id}".encode()).hexdigest()[:64]


def select_history(
    messages: list[Message], max_chars: int, with_attachments: Collection[uuid.UUID] = frozenset()
) -> list[Message]:
    """Completed user/assistant turns, newest first until the budget is used.

    The latest message is always included so the model sees the question.
    Messages with attachments count even without text.
    """
    usable = [
        m
        for m in messages
        if m.role in (MessageRole.USER, MessageRole.ASSISTANT)
        and m.status == MessageStatus.COMPLETE
        and (m.content or m.id in with_attachments)
    ]
    selected: list[Message] = []
    used = 0
    for message in reversed(usable):
        if selected and used + len(message.content) > max_chars:
            break
        selected.append(message)
        used += len(message.content)
    selected.reverse()
    # A conversation must not start with an assistant turn.
    while selected and selected[0].role != MessageRole.USER:
        selected.pop(0)
    return selected


class ChatService:
    def __init__(
        self,
        sessionmaker: async_sessionmaker[AsyncSession],
        registry: ProviderRegistry,
        settings: Settings,
        storage: AttachmentStorage | None = None,
    ) -> None:
        self._sessionmaker = sessionmaker
        self._registry = registry
        self._settings = settings
        self._storage = storage

    async def generate(
        self,
        *,
        user: User,
        conversation_id: uuid.UUID,
        request_id: str,
        content: str | None,
        emit: Emit,
        attachment_ids: Sequence[uuid.UUID] = (),
    ) -> None:
        """Answer ``content`` (a new user message, optionally with uploaded
        attachments), or re-answer the latest user message when ``content`` is
        None (regenerate)."""
        generation = await self._prepare(user, conversation_id, request_id, content, list(attachment_ids), emit)
        if generation is not None:
            await self._stream(generation, emit)

    # ------------------------------------------------------------------ attachments

    async def _claim_attachments(
        self, session: AsyncSession, user: User, ids: list[uuid.UUID], model: ModelInfo | None
    ) -> list[ConversationAttachment]:
        """The pending uploads to send, checked against the model. Raises AppError."""
        if self._storage is None:
            raise AppError("Attachments are not available on this server.", code="attachments_not_supported")
        attachments = await AttachmentService(session, self._storage, self._settings).pending_for_send(user, ids)
        if sum(a.size_bytes for a in attachments) > self._settings.attachment_context_max_bytes:
            limit_mb = self._settings.attachment_context_max_bytes // (1024 * 1024)
            raise AppError(
                f"These attachments are too large together (at most {limit_mb} MB per message).",
                code="attachments_too_large",
                status_code=413,
            )
        if model is not None:
            caps = model.capabilities
            unsupported = {
                a.kind
                for a in attachments
                if not kind_supported(a.kind, image_input=caps.image_input, pdf_input=caps.pdf_input)
            }
            if unsupported:
                what = " or ".join(sorted("images" if k == "image" else "PDF documents" for k in unsupported))
                raise AppError(
                    f"{model.display_name} cannot read {what}. Choose another model or remove the attachment.",
                    code="attachments_not_supported",
                )
        return attachments

    async def _build_turns(
        self,
        history: list[Message],
        attachments: dict[uuid.UUID, list[ConversationAttachment]],
        model: ModelInfo,
    ) -> list[ChatTurn]:
        """Turns with their files. Newest attachments get the request-size budget
        first; anything left out is named in the text, so the model knows it existed."""
        caps = model.capabilities
        budget = self._settings.attachment_context_max_bytes
        files: dict[uuid.UUID, list[ChatAttachment]] = {}
        notes: dict[uuid.UUID, list[str]] = {}
        for message in reversed(history):
            for attachment in attachments.get(message.id, []):
                label = "PDF" if attachment.kind == "pdf" else "image"
                note: str | None = None
                if not kind_supported(attachment.kind, image_input=caps.image_input, pdf_input=caps.pdf_input):
                    note = f'[Attached {label} "{attachment.filename}": this model cannot read it.]'
                elif attachment.size_bytes > budget or self._storage is None:
                    note = f'[Earlier {label} "{attachment.filename}" is not repeated (request size limit).]'
                else:
                    try:
                        data = await self._storage.read(attachment.storage_key)
                    except FileNotFoundError:
                        note = f'[Attached {label} "{attachment.filename}" is no longer available.]'
                    else:
                        budget -= attachment.size_bytes
                        files.setdefault(message.id, []).append(
                            ChatAttachment(
                                kind=attachment.kind,  # type: ignore[arg-type]
                                mime_type=attachment.content_type,
                                filename=attachment.filename,
                                data=data,
                            )
                        )
                if note:
                    notes.setdefault(message.id, []).append(note)
        turns: list[ChatTurn] = []
        for message in history:
            text = "\n\n".join(part for part in [message.content, *notes.get(message.id, [])] if part)
            turns.append(
                ChatTurn(
                    role=message.role.value,  # type: ignore[arg-type]
                    content=text,
                    attachments=files.get(message.id, []) if message.role == MessageRole.USER else [],
                )
            )
        return turns

    # ------------------------------------------------------------------ prepare

    def _resolve_target(self, provider_id: str | None, model_id: str | None) -> tuple[AIProvider, ModelInfo]:
        """The requested provider/model if still available, else the server defaults."""
        available = {p.id for p in self._registry.list()}
        provider = self._registry.resolve(provider_id if provider_id in available else None)
        model = provider.get_model(model_id) if model_id else None
        if model is not None and not model.capabilities.text_streaming:
            model = None  # e.g. a realtime voice model: not usable for text chat
        model = model or provider.default_model()
        if model is None:
            raise ProviderNotAvailableError(f"AI provider '{provider.id}' has no models configured")
        return provider, model

    async def _prepare(
        self,
        user: User,
        conversation_id: uuid.UUID,
        request_id: str,
        content: str | None,
        attachment_ids: list[uuid.UUID],
        emit: Emit,
    ) -> _Generation | None:
        def event(type_: str, **payload: Any) -> dict[str, Any]:
            return {"type": type_, "request_id": request_id, "conversation_id": str(conversation_id), **payload}

        pending: list[dict[str, Any]] = []
        # Before the transaction: Ollama may have new models (network call, rate limited).
        await self._registry.refresh()
        async with self._sessionmaker() as session:
            conversations = ConversationRepository(session)
            messages = MessageRepository(session)
            conversation = await conversations.get_for_user(conversation_id, user.id, for_update=True)
            if conversation is None:
                await emit(
                    event(
                        "response.failed",
                        message=None,
                        error=_error("conversation_not_found", "Conversation not found"),
                    )
                )
                return None

            title_before = conversation.title
            now = utcnow()
            # The model is resolved first: attachments must be readable by it.
            preferences = await PreferencesRepository(session).get_or_create(user.id)
            target: tuple[AIProvider, ModelInfo] | None = None
            target_error: ProviderNotAvailableError | None = None
            try:
                target = self._resolve_target(
                    conversation.provider or preferences.default_provider,
                    conversation.model or preferences.default_model,
                )
            except ProviderNotAvailableError as exc:
                target_error = exc

            if content is not None:
                new_attachments: list[ConversationAttachment] = []
                if attachment_ids:
                    try:
                        new_attachments = await self._claim_attachments(
                            session, user, attachment_ids, target[1] if target else None
                        )
                    except AppError as exc:
                        # Nothing is stored: the user can pick another model and resend.
                        await session.rollback()
                        await emit(event("response.failed", message=None, error=_error(exc.code, exc.message)))
                        return None
                seq = await messages.next_seq(conversation.id)
                user_message = await messages.create(
                    conversation_id=conversation.id, seq=seq, role=MessageRole.USER, content=content
                )
                for attachment in new_attachments:
                    attachment.conversation_id = conversation.id
                    attachment.message_id = user_message.id
                if seq == 1 and conversation.title == DEFAULT_CONVERSATION_TITLE:
                    conversation.title = derive_title(
                        content or (new_attachments[0].filename if new_attachments else "")
                    )
                pending.append(
                    event("message.created", message=_dump(MessageOut.from_model(user_message, new_attachments)))
                )
            else:
                last = await messages.list_recent(conversation.id, 1)
                if last and last[-1].role == MessageRole.ASSISTANT:
                    await messages.delete(last[-1])
                    pending.append(event("message.deleted", message_id=str(last[-1].id)))

            history = await messages.list_recent(conversation.id, self._settings.chat_history_max_messages)
            if not history or history[-1].role != MessageRole.USER:
                await session.commit()
                for item in pending:
                    await emit(item)
                await emit(
                    event(
                        "response.failed",
                        message=None,
                        error=_error("nothing_to_answer", "There is no message to reply to."),
                    )
                )
                return None

            if target is None:
                assert target_error is not None
                conversation.updated_at = now
                conversation.last_message_at = now
                await session.commit()
                for item in pending:
                    await emit(item)
                await emit(_conversation_event(event, conversation, title_before))
                await emit(
                    event("response.failed", message=None, error=_error(target_error.code, target_error.message))
                )
                return None
            provider, model = target

            # Remember the model actually used, so the UI shows it.
            conversation.provider, conversation.model = provider.id, model.id
            assistant = await messages.create(
                conversation_id=conversation.id,
                seq=await messages.next_seq(conversation.id),
                role=MessageRole.ASSISTANT,
                content="",
                status=MessageStatus.STREAMING,
                provider=provider.id,
                model=model.id,
            )
            conversation.updated_at = now
            conversation.last_message_at = now
            attachments = (
                await AttachmentService(session, self._storage, self._settings).for_messages(m.id for m in history)
                if self._storage is not None
                else {}
            )
            selected = select_history(history, self._settings.chat_history_max_chars, attachments.keys())
            turns = [ChatTurn(role="system", content=self._settings.chat_system_prompt)] + await self._build_turns(
                selected, attachments, model
            )
            await session.commit()

            for item in pending:
                await emit(item)
            await emit(_conversation_event(event, conversation, title_before))
            await emit(event("response.started", message=_dump(MessageOut.from_model(assistant))))

        return _Generation(
            request_id=request_id,
            conversation_id=conversation_id,
            message_id=assistant.id,
            provider=provider,
            model=model,
            request=ChatRequest(
                model=model.id,
                turns=turns,
                max_output_tokens=self._settings.chat_max_output_tokens,
                end_user_id=end_user_id(user.id),
            ),
        )

    # ------------------------------------------------------------------ stream

    async def _stream(self, generation: _Generation, emit: Emit) -> None:
        def event(type_: str, **payload: Any) -> dict[str, Any]:
            return {
                "type": type_,
                "request_id": generation.request_id,
                "conversation_id": str(generation.conversation_id),
                **payload,
            }

        status = MessageStatus.ERROR
        error: dict[str, str] | None = _error("provider_stream_interrupted", "The response ended unexpectedly.")
        try:
            async for chunk in generation.provider.stream_chat(generation.request):
                if chunk.type == "text_delta" and chunk.text:
                    generation.text.append(chunk.text)
                    await emit(event("response.delta", message_id=str(generation.message_id), delta=chunk.text))
                elif chunk.type == "usage":
                    generation.usage = chunk.usage
                elif chunk.type == "done":
                    generation.metadata.update(chunk.provider_metadata or {})
                    status, error = MessageStatus.COMPLETE, None
                    break
                elif chunk.type == "error":
                    error = _error(
                        chunk.error_code or "provider_error", chunk.error_message or "The AI provider failed."
                    )
                    break
        except asyncio.CancelledError:
            # Stopped by the user: keep what was generated so far.
            message = await asyncio.shield(self._finalize(generation, MessageStatus.CANCELLED, None))
            await _safe_emit(emit, event("response.cancelled", message=message))
            raise
        except ProviderError as exc:
            error = _error(exc.code, str(exc))
        except Exception:
            logger.exception("Generation %s failed", generation.request_id)
            error = _error("internal_error", "Something went wrong while generating the response.")

        message = await self._finalize(generation, status, error)
        if status == MessageStatus.COMPLETE:
            await emit(event("response.completed", message=message))
        else:
            await emit(event("response.failed", message=message, error=error))

    async def _finalize(
        self, generation: _Generation, status: MessageStatus, error: dict[str, str] | None
    ) -> dict[str, Any] | None:
        async with self._sessionmaker() as session:
            message = await session.get(Message, generation.message_id)
            if message is None:  # deleted while streaming (e.g. conversation removed)
                return None
            message.content = "".join(generation.text)
            message.status = status
            if generation.usage is not None:
                message.input_tokens = generation.usage.input_tokens
                message.output_tokens = generation.usage.output_tokens
                message.total_tokens = generation.usage.total_tokens
            extra = dict(generation.metadata)
            if error is not None:
                extra["error"] = error
            message.extra = extra or None
            conversation = await session.get(Conversation, generation.conversation_id)
            if conversation is not None:
                conversation.updated_at = utcnow()
            await session.commit()
            logger.info(
                "Generation %s finished: status=%s model=%s tokens=%s",
                generation.request_id,
                status.value,
                generation.model.id,
                generation.usage.total_tokens if generation.usage else "n/a",
            )
            return _dump(MessageOut.from_model(message))


def _dump(model: MessageOut | ConversationOut) -> dict[str, Any]:
    return model.model_dump(mode="json")


def _error(code: str, message: str) -> dict[str, str]:
    return {"code": code, "message": message}


def _conversation_event(
    event: Callable[..., dict[str, Any]], conversation: Conversation, title_before: str
) -> dict[str, Any]:
    payload = _dump(ConversationOut.model_validate(conversation))
    return event("conversation.updated", conversation=payload, title_changed=conversation.title != title_before)


async def _safe_emit(emit: Emit, payload: dict[str, Any]) -> None:
    try:
        await emit(payload)
    except Exception:  # the client may already be gone
        logger.debug("Could not deliver %s", payload.get("type"))

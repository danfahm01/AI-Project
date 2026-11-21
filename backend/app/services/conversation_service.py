import base64
import binascii
import json
import uuid
from collections.abc import Iterable
from datetime import datetime

from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.errors import AppError, NotFoundError, PermissionDeniedError
from app.db.base import utcnow
from app.models.attachment import ConversationAttachment
from app.models.conversation import DEFAULT_CONVERSATION_TITLE, Conversation
from app.models.message import Message, MessageRole
from app.models.user import User
from app.repositories.conversation_repository import ConversationRepository
from app.repositories.message_repository import MessageRepository
from app.schemas.conversation import ConversationCreate, ConversationUpdate
from app.schemas.message import MessageCreate, MessageUpdate
from app.services.attachment_storage import AttachmentStorage

TITLE_MAX_CHARS = 60


def derive_title(content: str) -> str:
    """Deterministic title from the first message (AI-generated titles arrive with phase 2)."""
    first_line = next((line.strip() for line in content.splitlines() if line.strip()), "")
    collapsed = " ".join(first_line.split())
    if not collapsed:
        return DEFAULT_CONVERSATION_TITLE
    if len(collapsed) <= TITLE_MAX_CHARS:
        return collapsed
    cut = collapsed[:TITLE_MAX_CHARS].rsplit(" ", 1)[0] or collapsed[:TITLE_MAX_CHARS]
    return cut.rstrip(" ,.;:-") + "…"


def encode_cursor(conversation: Conversation) -> str:
    payload = json.dumps({"u": conversation.updated_at.isoformat(), "i": str(conversation.id)})
    return base64.urlsafe_b64encode(payload.encode()).decode().rstrip("=")


def decode_cursor(cursor: str) -> tuple[datetime, uuid.UUID]:
    try:
        raw = base64.urlsafe_b64decode(cursor + "=" * (-len(cursor) % 4))
        data = json.loads(raw)
        updated_at = datetime.fromisoformat(data["u"])
        if updated_at.tzinfo is None:
            raise ValueError("cursor timestamp must be timezone-aware")
        return updated_at, uuid.UUID(data["i"])
    except (ValueError, KeyError, TypeError, binascii.Error) as exc:
        raise AppError("Invalid pagination cursor", code="invalid_cursor") from exc


class ConversationService:
    def __init__(self, session: AsyncSession, storage: AttachmentStorage | None = None) -> None:
        self.session = session
        self.conversations = ConversationRepository(session)
        self.messages = MessageRepository(session)
        # Needed to delete attachment files along with their messages.
        self.storage = storage

    async def attachments_for(self, message_ids: Iterable[uuid.UUID]) -> dict[uuid.UUID, list[ConversationAttachment]]:
        ids = list(message_ids)
        if not ids:
            return {}
        rows = (
            await self.session.scalars(
                select(ConversationAttachment)
                .where(ConversationAttachment.message_id.in_(ids))
                .order_by(ConversationAttachment.created_at, ConversationAttachment.id)
            )
        ).all()
        grouped: dict[uuid.UUID, list[ConversationAttachment]] = {}
        for attachment in rows:
            grouped.setdefault(attachment.message_id, []).append(attachment)  # type: ignore[arg-type]
        return grouped

    async def _delete_attachment_rows(self, attachments: Iterable[ConversationAttachment]) -> list[str]:
        items = list(attachments)
        if items:
            await self.session.execute(
                delete(ConversationAttachment)
                .where(ConversationAttachment.id.in_([a.id for a in items]))
                .execution_options(synchronize_session="fetch")
            )
        return [a.storage_key for a in items]

    async def _delete_files(self, keys: list[str]) -> None:
        if keys and self.storage is not None:
            await self.storage.delete_many(keys)

    # --- Conversations ---------------------------------------------------------

    async def list(
        self, user: User, *, query: str | None, limit: int, cursor: str | None
    ) -> tuple[list[Conversation], str | None]:
        after = decode_cursor(cursor) if cursor else None
        query = query.strip() if query else None
        rows = await self.conversations.list_for_user(user.id, query=query or None, limit=limit + 1, after=after)
        next_cursor = encode_cursor(rows[limit - 1]) if len(rows) > limit else None
        return rows[:limit], next_cursor

    async def create(self, user: User, data: ConversationCreate) -> Conversation:
        conversation = await self.conversations.create(
            user_id=user.id,
            title=data.title or DEFAULT_CONVERSATION_TITLE,
            provider=data.provider,
            model=data.model,
        )
        await self.session.commit()
        return conversation

    async def get(self, user: User, conversation_id: uuid.UUID, *, for_update: bool = False) -> Conversation:
        conversation = await self.conversations.get_for_user(conversation_id, user.id, for_update=for_update)
        if conversation is None:
            raise NotFoundError("Conversation not found", code="conversation_not_found")
        return conversation

    async def update(self, user: User, conversation_id: uuid.UUID, data: ConversationUpdate) -> Conversation:
        conversation = await self.get(user, conversation_id)
        for field in data.model_fields_set:
            setattr(conversation, field, getattr(data, field))
        await self.session.commit()
        return conversation

    async def delete(self, user: User, conversation_id: uuid.UUID) -> None:
        conversation = await self.get(user, conversation_id)
        attachments = (
            await self.session.scalars(
                select(ConversationAttachment).where(ConversationAttachment.conversation_id == conversation.id)
            )
        ).all()
        keys = await self._delete_attachment_rows(attachments)
        await self.conversations.delete(conversation)
        await self.session.commit()
        await self._delete_files(keys)

    # --- Messages ----------------------------------------------------------------

    async def list_messages(self, user: User, conversation_id: uuid.UUID) -> list[Message]:
        await self.get(user, conversation_id)
        return await self.messages.list_for_conversation(conversation_id)

    async def add_user_message(self, user: User, conversation_id: uuid.UUID, data: MessageCreate) -> Message:
        conversation = await self.get(user, conversation_id, for_update=True)
        seq = await self.messages.next_seq(conversation.id)
        message = await self.messages.create(
            conversation_id=conversation.id, seq=seq, role=MessageRole.USER, content=data.content
        )
        now = utcnow()
        conversation.last_message_at = now
        conversation.updated_at = now
        if seq == 1 and conversation.title == DEFAULT_CONVERSATION_TITLE:
            conversation.title = derive_title(data.content)
        await self.session.commit()
        return message

    async def edit_message(
        self, user: User, message_id: uuid.UUID, data: MessageUpdate
    ) -> tuple[Message, list[uuid.UUID]]:
        """Edit a user message. Later turns depended on the old text, so they are removed."""
        message = await self._get_message(user, message_id)
        if message.role != MessageRole.USER:
            raise PermissionDeniedError("Only user messages can be edited", code="message_not_editable")

        conversation = await self.get(user, message.conversation_id, for_update=True)
        later = [m.id for m in await self.messages.list_for_conversation(conversation.id) if m.seq > message.seq]
        keys = await self._delete_attachment_rows(
            [a for group in (await self.attachments_for(later)).values() for a in group]
        )
        removed_ids = await self.messages.delete_after(conversation.id, message.seq)
        now = utcnow()
        message.content = data.content
        message.edited_at = now
        conversation.updated_at = now
        await self.session.commit()
        await self._delete_files(keys)
        return message, removed_ids

    async def delete_message(self, user: User, message_id: uuid.UUID) -> None:
        message = await self._get_message(user, message_id)
        keys = await self._delete_attachment_rows((await self.attachments_for([message.id])).get(message.id, []))
        await self.messages.delete(message)
        await self.session.commit()
        await self._delete_files(keys)

    async def _get_message(self, user: User, message_id: uuid.UUID) -> Message:
        message = await self.messages.get_for_user(message_id, user.id)
        if message is None:
            raise NotFoundError("Message not found", code="message_not_found")
        return message

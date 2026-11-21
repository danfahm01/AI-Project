import uuid
from typing import Any

from sqlalchemy import delete, func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.conversation import Conversation
from app.models.message import Message, MessageRole, MessageStatus


class MessageRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def list_for_conversation(self, conversation_id: uuid.UUID) -> list[Message]:
        stmt = select(Message).where(Message.conversation_id == conversation_id).order_by(Message.seq)
        return list((await self.session.scalars(stmt)).all())

    async def list_recent(self, conversation_id: uuid.UUID, limit: int) -> list[Message]:
        """The newest ``limit`` messages, oldest first (uses the (conversation_id, seq) index)."""
        stmt = (
            select(Message).where(Message.conversation_id == conversation_id).order_by(Message.seq.desc()).limit(limit)
        )
        return list(reversed((await self.session.scalars(stmt)).all()))

    async def next_seq(self, conversation_id: uuid.UUID) -> int:
        current = await self.session.scalar(
            select(func.coalesce(func.max(Message.seq), 0)).where(Message.conversation_id == conversation_id)
        )
        return int(current or 0) + 1

    async def create(
        self,
        *,
        conversation_id: uuid.UUID,
        seq: int,
        role: MessageRole,
        content: str,
        status: MessageStatus = MessageStatus.COMPLETE,
        **fields: Any,
    ) -> Message:
        message = Message(conversation_id=conversation_id, seq=seq, role=role, content=content, status=status, **fields)
        self.session.add(message)
        await self.session.flush()
        return message

    async def get_for_user(self, message_id: uuid.UUID, user_id: uuid.UUID) -> Message | None:
        stmt = (
            select(Message)
            .join(Conversation, Conversation.id == Message.conversation_id)
            .where(Message.id == message_id, Conversation.user_id == user_id)
        )
        return await self.session.scalar(stmt)

    async def delete_after(self, conversation_id: uuid.UUID, seq: int) -> list[uuid.UUID]:
        """Delete every message after position ``seq``; return the removed ids."""
        ids = list(
            (
                await self.session.scalars(
                    select(Message.id).where(Message.conversation_id == conversation_id, Message.seq > seq)
                )
            ).all()
        )
        if ids:
            await self.session.execute(
                delete(Message).where(Message.id.in_(ids)).execution_options(synchronize_session="fetch")
            )
        return ids

    async def delete(self, message: Message) -> None:
        await self.session.delete(message)
        # Sessions run with autoflush disabled; flush so follow-up queries in the
        # same transaction no longer see the row.
        await self.session.flush()

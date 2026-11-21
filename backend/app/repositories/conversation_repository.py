import uuid
from datetime import datetime

from sqlalchemy import and_, exists, or_, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.conversation import Conversation
from app.models.message import Message


def escape_like(value: str) -> str:
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


class ConversationRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def create(self, *, user_id: uuid.UUID, title: str, provider: str | None, model: str | None) -> Conversation:
        conversation = Conversation(user_id=user_id, title=title, provider=provider, model=model)
        self.session.add(conversation)
        await self.session.flush()
        return conversation

    async def get_for_user(
        self, conversation_id: uuid.UUID, user_id: uuid.UUID, *, for_update: bool = False
    ) -> Conversation | None:
        stmt = select(Conversation).where(Conversation.id == conversation_id, Conversation.user_id == user_id)
        if for_update:
            # Serialises concurrent writers on PostgreSQL; ignored by SQLite (single writer anyway).
            stmt = stmt.with_for_update()
        return await self.session.scalar(stmt)

    async def list_for_user(
        self,
        user_id: uuid.UUID,
        *,
        query: str | None,
        limit: int,
        after: tuple[datetime, uuid.UUID] | None,
    ) -> list[Conversation]:
        stmt = select(Conversation).where(Conversation.user_id == user_id)

        if query:
            pattern = f"%{escape_like(query)}%"
            message_match = exists().where(
                Message.conversation_id == Conversation.id,
                Message.content.ilike(pattern, escape="\\"),
            )
            stmt = stmt.where(or_(Conversation.title.ilike(pattern, escape="\\"), message_match))

        if after is not None:
            updated_at, conversation_id = after
            stmt = stmt.where(
                or_(
                    Conversation.updated_at < updated_at,
                    and_(Conversation.updated_at == updated_at, Conversation.id < conversation_id),
                )
            )

        stmt = stmt.order_by(Conversation.updated_at.desc(), Conversation.id.desc()).limit(limit)
        return list((await self.session.scalars(stmt)).all())

    async def delete(self, conversation: Conversation) -> None:
        # Messages and attachments are removed by ON DELETE CASCADE.
        await self.session.delete(conversation)

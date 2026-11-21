import uuid
from typing import Annotated

from fastapi import APIRouter, Depends, Query, Response, status

from app.api.deps import CurrentUser, DbSession, limit_api_requests
from app.api.v1.attachments import StorageDep
from app.schemas.conversation import ConversationCreate, ConversationOut, ConversationPage, ConversationUpdate
from app.schemas.message import MessageCreate, MessageList, MessageOut
from app.services.conversation_service import ConversationService

router = APIRouter(prefix="/conversations", tags=["conversations"], dependencies=[Depends(limit_api_requests)])


@router.get("", response_model=ConversationPage, summary="List conversations, newest activity first")
async def list_conversations(
    user: CurrentUser,
    session: DbSession,
    q: Annotated[str | None, Query(max_length=200, description="Search titles and message text")] = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 30,
    cursor: Annotated[str | None, Query(max_length=500)] = None,
) -> ConversationPage:
    items, next_cursor = await ConversationService(session).list(user, query=q, limit=limit, cursor=cursor)
    return ConversationPage(items=[ConversationOut.model_validate(c) for c in items], next_cursor=next_cursor)


@router.post("", response_model=ConversationOut, status_code=status.HTTP_201_CREATED)
async def create_conversation(body: ConversationCreate, user: CurrentUser, session: DbSession) -> ConversationOut:
    return ConversationOut.model_validate(await ConversationService(session).create(user, body))


@router.get("/{conversation_id}", response_model=ConversationOut)
async def get_conversation(conversation_id: uuid.UUID, user: CurrentUser, session: DbSession) -> ConversationOut:
    return ConversationOut.model_validate(await ConversationService(session).get(user, conversation_id))


@router.patch("/{conversation_id}", response_model=ConversationOut, summary="Rename or change the model")
async def update_conversation(
    conversation_id: uuid.UUID, body: ConversationUpdate, user: CurrentUser, session: DbSession
) -> ConversationOut:
    return ConversationOut.model_validate(await ConversationService(session).update(user, conversation_id, body))


@router.delete("/{conversation_id}", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def delete_conversation(
    conversation_id: uuid.UUID, user: CurrentUser, session: DbSession, storage: StorageDep
) -> Response:
    await ConversationService(session, storage).delete(user, conversation_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.get("/{conversation_id}/messages", response_model=MessageList)
async def list_messages(conversation_id: uuid.UUID, user: CurrentUser, session: DbSession) -> MessageList:
    service = ConversationService(session)
    messages = await service.list_messages(user, conversation_id)
    attachments = await service.attachments_for(m.id for m in messages)
    return MessageList(items=[MessageOut.from_model(m, attachments.get(m.id, [])) for m in messages])


@router.post(
    "/{conversation_id}/messages",
    response_model=MessageOut,
    status_code=status.HTTP_201_CREATED,
    summary="Add a user message",
)
async def create_message(
    conversation_id: uuid.UUID, body: MessageCreate, user: CurrentUser, session: DbSession
) -> MessageOut:
    message = await ConversationService(session).add_user_message(user, conversation_id, body)
    return MessageOut.from_model(message)

import uuid

from fastapi import APIRouter, Depends, Response, status

from app.api.deps import CurrentUser, DbSession, limit_api_requests
from app.api.v1.attachments import StorageDep
from app.schemas.message import MessageEditResult, MessageOut, MessageUpdate
from app.services.conversation_service import ConversationService

router = APIRouter(prefix="/messages", tags=["messages"], dependencies=[Depends(limit_api_requests)])


@router.patch(
    "/{message_id}",
    response_model=MessageEditResult,
    summary="Edit a user message's text (removes the turns that followed it; attachments stay)",
)
async def edit_message(
    message_id: uuid.UUID, body: MessageUpdate, user: CurrentUser, session: DbSession, storage: StorageDep
) -> MessageEditResult:
    service = ConversationService(session, storage)
    message, removed_ids = await service.edit_message(user, message_id, body)
    attachments = (await service.attachments_for([message.id])).get(message.id, [])
    return MessageEditResult(message=MessageOut.from_model(message, attachments), removed_message_ids=removed_ids)


@router.delete("/{message_id}", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def delete_message(message_id: uuid.UUID, user: CurrentUser, session: DbSession, storage: StorageDep) -> Response:
    await ConversationService(session, storage).delete_message(user, message_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)

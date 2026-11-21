"""Attachment uploads and downloads.

Files are served with their detected type, ``X-Content-Type-Options: nosniff``
and a download-safe ``Content-Disposition``. Only PNG, JPEG, WEBP and PDF are
accepted, so nothing served here is HTML or script.
"""

import uuid
from typing import Annotated
from urllib.parse import quote

from fastapi import APIRouter, Depends, File, Query, Request, Response, UploadFile, status

from app.api.deps import CurrentUser, DbSession, SettingsDep, enforce_rate_limit, limit_api_requests
from app.core.errors import NotFoundError
from app.models.attachment import ConversationAttachment
from app.schemas.attachment import AttachmentLink, AttachmentOut
from app.services.attachment_service import AttachmentService
from app.services.attachment_storage import AttachmentStorage

router = APIRouter(prefix="/attachments", tags=["attachments"])


def get_storage(request: Request) -> AttachmentStorage:
    return request.app.state.attachment_storage


StorageDep = Annotated[AttachmentStorage, Depends(get_storage)]


async def limit_uploads(request: Request, settings: SettingsDep, user: CurrentUser) -> None:
    await enforce_rate_limit(request, f"upload:{user.id}", settings.rate_limit_uploads_per_minute)


def _file_response(attachment: ConversationAttachment, data: bytes, *, cache_seconds: int) -> Response:
    # RFC 6266 / 5987: an ASCII fallback plus the UTF-8 name.
    ascii_name = attachment.filename.encode("ascii", "replace").decode().replace('"', "'")
    disposition = f"inline; filename=\"{ascii_name}\"; filename*=UTF-8''{quote(attachment.filename)}"
    return Response(
        content=data,
        media_type=attachment.content_type,
        headers={
            "Content-Disposition": disposition,
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": f"private, max-age={cache_seconds}",
        },
    )


@router.post(
    "",
    response_model=AttachmentOut,
    status_code=status.HTTP_201_CREATED,
    summary="Upload an image or PDF to send with a message",
    dependencies=[Depends(limit_uploads)],
)
async def upload_attachment(
    file: Annotated[UploadFile, File(description="PNG, JPEG, WEBP or PDF")],
    user: CurrentUser,
    session: DbSession,
    storage: StorageDep,
    settings: SettingsDep,
) -> AttachmentOut:
    attachment = await AttachmentService(session, storage, settings).upload(user, file)
    return AttachmentOut.from_model(attachment)


@router.get("/{attachment_id}", response_model=AttachmentOut, dependencies=[Depends(limit_api_requests)])
async def get_attachment(
    attachment_id: uuid.UUID, user: CurrentUser, session: DbSession, storage: StorageDep, settings: SettingsDep
) -> AttachmentOut:
    return AttachmentOut.from_model(
        await AttachmentService(session, storage, settings).get_for_user(user, attachment_id)
    )


@router.get(
    "/{attachment_id}/content",
    summary="The file itself (for thumbnails in the app)",
    dependencies=[Depends(limit_api_requests)],
    response_class=Response,
)
async def get_attachment_content(
    attachment_id: uuid.UUID, user: CurrentUser, session: DbSession, storage: StorageDep, settings: SettingsDep
) -> Response:
    service = AttachmentService(session, storage, settings)
    attachment = await service.get_for_user(user, attachment_id)
    return _file_response(attachment, await service.read(attachment), cache_seconds=3600)


@router.post(
    "/{attachment_id}/link",
    response_model=AttachmentLink,
    summary="A short-lived download link, e.g. to open a PDF in the system viewer",
    dependencies=[Depends(limit_api_requests)],
)
async def create_attachment_link(
    attachment_id: uuid.UUID, user: CurrentUser, session: DbSession, storage: StorageDep, settings: SettingsDep
) -> AttachmentLink:
    service = AttachmentService(session, storage, settings)
    path, expires_at = service.signed_path(await service.get_for_user(user, attachment_id))
    return AttachmentLink(path=path, expires_at=expires_at)


@router.get("/{attachment_id}/download", summary="Download with a signed link", response_class=Response)
async def download_attachment(
    attachment_id: uuid.UUID,
    expires: Annotated[int, Query()],
    signature: Annotated[str, Query(max_length=128)],
    session: DbSession,
    storage: StorageDep,
    settings: SettingsDep,
) -> Response:
    service = AttachmentService(session, storage, settings)
    attachment = await session.get(ConversationAttachment, attachment_id)
    # Same answer for a bad signature and a missing file: nothing to probe.
    if attachment is None or not service.verify_signature(attachment_id, expires, signature):
        raise NotFoundError("This link has expired or is not valid", code="attachment_link_invalid")
    return _file_response(attachment, await service.read(attachment), cache_seconds=60)


@router.delete(
    "/{attachment_id}",
    status_code=status.HTTP_204_NO_CONTENT,
    response_class=Response,
    summary="Remove an upload that has not been sent",
    dependencies=[Depends(limit_api_requests)],
)
async def delete_attachment(
    attachment_id: uuid.UUID, user: CurrentUser, session: DbSession, storage: StorageDep, settings: SettingsDep
) -> Response:
    await AttachmentService(session, storage, settings).delete(user, attachment_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)

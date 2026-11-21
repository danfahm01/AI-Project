"""Attachments: uploads, validation, linking to messages and clean-up.

* The file type is detected from the bytes (PNG, JPEG, WEBP, PDF); the client's
  declared type and file name are never trusted.
* Uploads are *pending* until sent with a message. Pending uploads older than
  ``ATTACHMENT_PENDING_TTL_HOURS`` are removed on the user's next upload.
* Deleting a message or conversation deletes its attachments' files too.
* Download links for opening files outside the app are signed (HMAC-SHA256 with
  the JWT secret), scoped to one attachment and short-lived.
"""

import base64
import hashlib
import hmac
import logging
import unicodedata
import uuid
from collections.abc import Iterable
from datetime import UTC, datetime, timedelta

from fastapi import UploadFile
from sqlalchemy import delete, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.core.config import Settings
from app.core.errors import AppError, NotFoundError
from app.db.base import utcnow
from app.models.attachment import IMAGE_TYPES, PDF_TYPE, ConversationAttachment
from app.models.user import User
from app.services.attachment_storage import AttachmentStorage

logger = logging.getLogger(__name__)

READ_CHUNK = 1024 * 1024
EXTENSIONS = {"image/png": ".png", "image/jpeg": ".jpg", "image/webp": ".webp", PDF_TYPE: ".pdf"}
MAX_FILENAME_CHARS = 120


class AttachmentTooLargeError(AppError):
    status_code = 413
    code = "attachment_too_large"


class UnsupportedAttachmentError(AppError):
    status_code = 415
    code = "attachment_type_not_supported"
    default_message = "Only PNG, JPEG and WEBP images and PDF documents can be attached."


def sniff_content_type(head: bytes) -> str | None:
    """The file type from its first bytes (magic numbers), or None if unsupported."""
    if head.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if head.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if len(head) >= 12 and head[:4] == b"RIFF" and head[8:12] == b"WEBP":
        return "image/webp"
    if head.startswith(b"%PDF-"):
        return PDF_TYPE
    return None


def clean_filename(name: str | None, content_type: str) -> str:
    """A safe display name: no path, no control characters, the right extension."""
    base = (name or "").replace("\\", "/").rsplit("/", 1)[-1]
    base = unicodedata.normalize("NFC", base)
    base = "".join(ch for ch in base if ch.isprintable() and ch not in '<>:"|?*').strip(" .")
    expected = EXTENSIONS[content_type]
    stem, dot, extension = base.rpartition(".")
    if not dot:
        stem, extension = base, ""
    accepted = {expected, ".jpeg"} if content_type == "image/jpeg" else {expected}
    if f".{extension.lower()}" not in accepted:
        stem, extension = base, expected.lstrip(".")
    stem = (stem or "attachment")[: MAX_FILENAME_CHARS - len(extension) - 1]
    return f"{stem}.{extension}"


def kind_supported(kind: str, *, image_input: bool, pdf_input: bool) -> bool:
    return image_input if kind == "image" else pdf_input


class AttachmentService:
    def __init__(self, session: AsyncSession, storage: AttachmentStorage, settings: Settings) -> None:
        self.session = session
        self.storage = storage
        self.settings = settings

    # ------------------------------------------------------------------ upload

    async def upload(self, user: User, file: UploadFile) -> ConversationAttachment:
        limit = self.settings.attachment_max_bytes
        chunks: list[bytes] = []
        size = 0
        while chunk := await file.read(READ_CHUNK):
            size += len(chunk)
            if size > limit:
                raise AttachmentTooLargeError(f"Files can be at most {limit // (1024 * 1024)} MB.")
            chunks.append(chunk)
        data = b"".join(chunks)
        if not data:
            raise AppError("The file is empty.", code="attachment_empty")
        content_type = sniff_content_type(data[:16])
        if content_type is None or content_type not in IMAGE_TYPES | {PDF_TYPE}:
            raise UnsupportedAttachmentError()

        await self._purge_stale_pending(user.id)
        attachment = ConversationAttachment(
            id=uuid.uuid4(),
            user_id=user.id,
            conversation_id=None,
            message_id=None,
            filename=clean_filename(file.filename, content_type),
            content_type=content_type,
            size_bytes=len(data),
            sha256=hashlib.sha256(data).hexdigest(),
            storage_key="",
        )
        attachment.storage_key = AttachmentStorage.key_for(user.id, attachment.id)
        await self.storage.save(attachment.storage_key, data)
        self.session.add(attachment)
        try:
            await self.session.commit()
        except Exception:
            await self.storage.delete(attachment.storage_key)
            raise
        logger.info("Attachment %s uploaded (%s, %d bytes)", attachment.id, content_type, len(data))
        return attachment

    async def _purge_stale_pending(self, user_id: uuid.UUID) -> None:
        cutoff = utcnow() - timedelta(hours=self.settings.attachment_pending_ttl_hours)
        stale = list(
            (
                await self.session.scalars(
                    select(ConversationAttachment).where(
                        ConversationAttachment.user_id == user_id,
                        ConversationAttachment.message_id.is_(None),
                        ConversationAttachment.created_at < cutoff,
                    )
                )
            ).all()
        )
        if stale:
            await self.remove(stale)

    # ------------------------------------------------------------------ access

    async def get_for_user(self, user: User, attachment_id: uuid.UUID) -> ConversationAttachment:
        attachment = await self.session.get(ConversationAttachment, attachment_id)
        if attachment is None or attachment.user_id != user.id:
            raise NotFoundError("Attachment not found", code="attachment_not_found")
        return attachment

    async def read(self, attachment: ConversationAttachment) -> bytes:
        try:
            return await self.storage.read(attachment.storage_key)
        except FileNotFoundError:
            raise NotFoundError("The attachment's file is missing", code="attachment_not_found") from None

    async def delete(self, user: User, attachment_id: uuid.UUID) -> None:
        """Remove an upload that has not been sent (sent ones go with their message)."""
        attachment = await self.get_for_user(user, attachment_id)
        if attachment.message_id is not None:
            raise AppError(
                "Attachments of sent messages are removed with the message", code="attachment_in_use", status_code=409
            )
        await self.remove([attachment])

    async def remove(self, attachments: Iterable[ConversationAttachment]) -> None:
        """Delete rows, commit, then delete the files (a missing file is harmless)."""
        keys = await self.delete_rows(attachments)
        await self.session.commit()
        await self.storage.delete_many(keys)

    async def delete_rows(self, attachments: Iterable[ConversationAttachment]) -> list[str]:
        """Delete rows in the current transaction; returns the storage keys to delete
        once it is committed (files are never removed before the rows are)."""
        items = list(attachments)
        if not items:
            return []
        await self.session.execute(
            delete(ConversationAttachment)
            .where(ConversationAttachment.id.in_([a.id for a in items]))
            .execution_options(synchronize_session="fetch")
        )
        return [a.storage_key for a in items]

    # ------------------------------------------------------------------ messages

    async def pending_for_send(self, user: User, ids: list[uuid.UUID]) -> list[ConversationAttachment]:
        """The user's unsent uploads with these ids, in the given order."""
        if len(ids) > self.settings.attachments_per_message:
            raise AppError(
                f"A message can have at most {self.settings.attachments_per_message} attachments.",
                code="too_many_attachments",
            )
        rows = (
            await self.session.scalars(
                select(ConversationAttachment).where(
                    ConversationAttachment.id.in_(ids),
                    ConversationAttachment.user_id == user.id,
                    ConversationAttachment.message_id.is_(None),
                )
            )
        ).all()
        by_id = {a.id: a for a in rows}
        missing = [i for i in ids if i not in by_id]
        if missing:
            raise NotFoundError(
                "An attachment was not found or was already sent. Attach the file again.",
                code="attachment_not_found",
            )
        return [by_id[i] for i in ids]

    async def for_messages(self, message_ids: Iterable[uuid.UUID]) -> dict[uuid.UUID, list[ConversationAttachment]]:
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
            assert attachment.message_id is not None
            grouped.setdefault(attachment.message_id, []).append(attachment)
        return grouped

    async def for_conversation(self, conversation_id: uuid.UUID) -> list[ConversationAttachment]:
        return list(
            (
                await self.session.scalars(
                    select(ConversationAttachment).where(ConversationAttachment.conversation_id == conversation_id)
                )
            ).all()
        )

    # ------------------------------------------------------------------ signed links

    def _signature(self, attachment_id: uuid.UUID, expires: int) -> str:
        key = self.settings.jwt_secret.get_secret_value().encode()
        digest = hmac.new(key, f"attachment:{attachment_id}:{expires}".encode(), hashlib.sha256).digest()
        return base64.urlsafe_b64encode(digest).decode().rstrip("=")

    def signed_path(self, attachment: ConversationAttachment) -> tuple[str, datetime]:
        expires_at = datetime.now(UTC) + timedelta(seconds=self.settings.attachment_link_ttl_seconds)
        expires = int(expires_at.timestamp())
        signature = self._signature(attachment.id, expires)
        return f"/attachments/{attachment.id}/download?expires={expires}&signature={signature}", expires_at

    def verify_signature(self, attachment_id: uuid.UUID, expires: int, signature: str) -> bool:
        if expires < int(datetime.now(UTC).timestamp()):
            return False
        return hmac.compare_digest(self._signature(attachment_id, expires), signature)

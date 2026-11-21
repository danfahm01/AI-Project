"""Realtime voice sessions.

The backend never relays audio: it mints a short-lived, session-scoped
credential with its permanent API key, and the client connects directly to the
provider (lowest latency). Transcripts come back through
``add_transcript`` so voice turns appear in the conversation history.
"""

import logging
import uuid
from datetime import timedelta

from sqlalchemy.ext.asyncio import AsyncSession

from app.ai_providers.base import AIProvider, ModelInfo, ProviderError, RealtimeSessionRequest
from app.ai_providers.registry import ProviderNotAvailableError, ProviderRegistry
from app.core.config import Settings
from app.core.errors import AppError, NotFoundError
from app.db.base import utcnow
from app.models.conversation import DEFAULT_CONVERSATION_TITLE, Conversation
from app.models.message import Message, MessageRole, MessageStatus
from app.models.preferences import UserPreferences, VoiceMode
from app.models.user import User
from app.models.voice_session import VoiceSession
from app.repositories.conversation_repository import ConversationRepository
from app.repositories.message_repository import MessageRepository
from app.repositories.preferences_repository import PreferencesRepository
from app.schemas.voice import TranscriptCreate, VoiceSessionCreate, VoiceSessionOut
from app.services.chat_service import end_user_id
from app.services.conversation_service import derive_title

logger = logging.getLogger(__name__)

# Transcripts are accepted for a while after the session started (the provider
# caps a realtime session at 60 minutes).
TRANSCRIPT_WINDOW = timedelta(hours=2)


class VoiceProviderError(AppError):
    status_code = 502
    code = "provider_error"
    default_message = "The AI provider could not start the voice session."


def build_voice_instructions(base: str, preferences: UserPreferences, history: list[Message], max_chars: int) -> str:
    """System instructions: the voice persona, the user's language, and recent
    conversation text so a voice session can continue a typed chat."""
    parts = [base]
    if preferences.language:
        parts.append(f"The user's preferred language is {preferences.language}; reply in it unless asked otherwise.")
    lines: list[str] = []
    used = 0
    for message in reversed(history):
        if message.role not in (MessageRole.USER, MessageRole.ASSISTANT) or message.status != MessageStatus.COMPLETE:
            continue
        line = f"{message.role.value}: {message.content.strip()}"
        if used + len(line) > max_chars:
            break
        lines.append(line)
        used += len(line)
    if lines:
        parts.append("Conversation so far (most recent last):\n" + "\n".join(reversed(lines)))
    return "\n\n".join(parts)


class VoiceService:
    def __init__(self, session: AsyncSession, registry: ProviderRegistry, settings: Settings) -> None:
        self.session = session
        self.registry = registry
        self.settings = settings
        self.conversations = ConversationRepository(session)
        self.messages = MessageRepository(session)

    def _resolve_realtime(self, provider_id: str | None, model_id: str | None) -> tuple[AIProvider, ModelInfo]:
        """The requested realtime model, else the first realtime model of the
        requested/default provider, else of any provider."""
        providers = self.registry.list()
        ordered = sorted(
            providers,
            key=lambda p: (p.id != provider_id, p.id != self.registry.default_id),
        )
        for provider in ordered:
            realtime = [m for m in provider.list_models() if m.capabilities.realtime_voice]
            chosen = next((m for m in realtime if m.id == model_id), None) or (realtime[0] if realtime else None)
            if chosen is not None:
                return provider, chosen
        raise ProviderNotAvailableError("No realtime voice model is configured on this server")

    async def start(self, user: User, data: VoiceSessionCreate) -> VoiceSessionOut:
        preferences = await PreferencesRepository(self.session).get_or_create(user.id)
        if data.provider is not None:
            provider, model = self._resolve_realtime(data.provider, data.model)
        else:  # the user's chosen voice model, else the server default
            provider, model = self._resolve_realtime(preferences.voice_provider, preferences.voice_model)

        if data.conversation_id is not None:
            conversation = await self.conversations.get_for_user(data.conversation_id, user.id)
            if conversation is None:
                raise NotFoundError("Conversation not found", code="conversation_not_found")
        else:
            conversation = await self.conversations.create(
                user_id=user.id, title=DEFAULT_CONVERSATION_TITLE, provider=None, model=None
            )

        hands_free = preferences.voice_mode == VoiceMode.HANDS_FREE and preferences.auto_speech_detection
        history = await self.messages.list_for_conversation(conversation.id)
        voice = (
            preferences.voice_name if any(v.id == preferences.voice_name for v in model.capabilities.voices) else None
        )

        try:
            descriptor = await provider.create_realtime_session(
                RealtimeSessionRequest(
                    model=model.id,
                    voice=voice,
                    language=preferences.language,
                    instructions=build_voice_instructions(
                        self.settings.voice_system_prompt, preferences, history, self.settings.voice_context_max_chars
                    ),
                    server_vad=hands_free,
                    speaking_rate=preferences.speaking_rate,
                    end_user_id=end_user_id(user.id),
                )
            )
        except ProviderError as exc:
            await self.session.rollback()
            raise VoiceProviderError(str(exc), code=exc.code) from exc

        record = VoiceSession(
            user_id=user.id,
            conversation_id=conversation.id,
            provider=provider.id,
            model=model.id,
            voice=descriptor.config.get("voice"),
            token_expires_at=descriptor.expires_at,
        )
        self.session.add(record)
        await self.session.commit()
        logger.info("Voice session %s started (model=%s, hands_free=%s)", record.id, model.id, hands_free)

        return VoiceSessionOut(
            id=record.id,
            conversation_id=conversation.id,
            provider=provider.id,
            model=model.id,
            transport=descriptor.transport,
            endpoint=descriptor.endpoint,
            client_secret=descriptor.client_secret.get_secret_value(),
            expires_at=descriptor.expires_at,
            voice=record.voice,
            push_to_talk=not hands_free,
            data_channel=descriptor.config.get("data_channel"),
            input_audio_format=descriptor.config.get("input_audio_format"),
            output_sample_rate=descriptor.config.get("output_sample_rate"),
            session_expires_at=descriptor.config.get("session_expires_at"),
        )

    async def _get_session(self, user: User, session_id: uuid.UUID) -> VoiceSession:
        record = await self.session.get(VoiceSession, session_id)
        if record is None or record.user_id != user.id:
            raise NotFoundError("Voice session not found", code="voice_session_not_found")
        return record

    async def add_transcript(self, user: User, session_id: uuid.UUID, data: TranscriptCreate) -> Message:
        record = await self._get_session(user, session_id)
        if utcnow() - record.created_at > TRANSCRIPT_WINDOW:
            raise AppError(
                "This voice session is too old to add transcripts", code="voice_session_expired", status_code=409
            )

        conversation: Conversation | None = await self.conversations.get_for_user(
            record.conversation_id, user.id, for_update=True
        )
        if conversation is None:
            raise NotFoundError("Conversation not found", code="conversation_not_found")

        # Idempotent per provider item: a retried upload returns the stored message.
        if data.item_id:
            for existing in reversed(await self.messages.list_for_conversation(conversation.id)):
                metadata = existing.audio_metadata or {}
                if metadata.get("voice_session_id") == str(record.id) and metadata.get("item_id") == data.item_id:
                    return existing

        seq = await self.messages.next_seq(conversation.id)
        role = MessageRole(data.role)
        message = await self.messages.create(
            conversation_id=conversation.id,
            seq=seq,
            role=role,
            content=data.content,
            provider=record.provider if role == MessageRole.ASSISTANT else None,
            model=record.model if role == MessageRole.ASSISTANT else None,
            audio_metadata={
                "source": "voice",
                "voice_session_id": str(record.id),
                "item_id": data.item_id,
                "duration_ms": data.duration_ms,
                "voice": record.voice if role == MessageRole.ASSISTANT else None,
            },
        )
        now = utcnow()
        conversation.updated_at = now
        conversation.last_message_at = now
        if role == MessageRole.USER and conversation.title == DEFAULT_CONVERSATION_TITLE:
            conversation.title = derive_title(data.content)
        await self.session.commit()
        return message

    async def end(self, user: User, session_id: uuid.UUID) -> None:
        record = await self._get_session(user, session_id)
        if record.ended_at is None:
            record.ended_at = utcnow()
            await self.session.commit()

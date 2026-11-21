"""Import every model so ``Base.metadata`` is complete (Alembic autogenerate relies on this)."""

from app.models.attachment import ConversationAttachment
from app.models.conversation import Conversation
from app.models.message import Message, MessageRole, MessageStatus
from app.models.preferences import ThemeMode, UserPreferences, VoiceMode
from app.models.provider_settings import AIProviderSetting
from app.models.refresh_token import RefreshToken
from app.models.user import User
from app.models.voice_session import VoiceSession

__all__ = [
    "AIProviderSetting",
    "Conversation",
    "ConversationAttachment",
    "Message",
    "MessageRole",
    "MessageStatus",
    "RefreshToken",
    "ThemeMode",
    "User",
    "UserPreferences",
    "VoiceMode",
    "VoiceSession",
]

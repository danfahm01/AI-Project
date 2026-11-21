from sqlalchemy.ext.asyncio import AsyncSession

from app.models.preferences import UserPreferences
from app.models.user import User
from app.repositories.preferences_repository import PreferencesRepository
from app.schemas.preferences import AudioSettings, PreferencesOut, PreferencesUpdate
from app.schemas.user import UserUpdate


def preferences_out(preferences: UserPreferences) -> PreferencesOut:
    return PreferencesOut(
        theme=preferences.theme,
        language=preferences.language,
        default_provider=preferences.default_provider,
        default_model=preferences.default_model,
        voice_provider=preferences.voice_provider,
        voice_model=preferences.voice_model,
        voice_name=preferences.voice_name,
        speaking_rate=preferences.speaking_rate,
        auto_speech_detection=preferences.auto_speech_detection,
        voice_mode=preferences.voice_mode,
        audio_settings=AudioSettings.model_validate(preferences.audio_settings or {}),
        updated_at=preferences.updated_at,
    )


class UserService:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session
        self.preferences = PreferencesRepository(session)

    async def update_profile(self, user: User, data: UserUpdate) -> User:
        user.display_name = data.display_name
        await self.session.commit()
        return user

    async def get_preferences(self, user: User) -> UserPreferences:
        preferences = await self.preferences.get_or_create(user.id)
        await self.session.commit()
        return preferences

    async def update_preferences(self, user: User, data: PreferencesUpdate) -> UserPreferences:
        preferences = await self.preferences.get_or_create(user.id)
        for field in data.model_fields_set:
            value = getattr(data, field)
            if field == "audio_settings":
                value = value.model_dump() if value is not None else None
            setattr(preferences, field, value)
        await self.session.commit()
        return preferences

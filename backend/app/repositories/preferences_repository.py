import uuid

from sqlalchemy.ext.asyncio import AsyncSession

from app.models.preferences import UserPreferences


class PreferencesRepository:
    def __init__(self, session: AsyncSession) -> None:
        self.session = session

    async def get_or_create(self, user_id: uuid.UUID) -> UserPreferences:
        preferences = await self.session.get(UserPreferences, user_id)
        if preferences is None:
            preferences = UserPreferences(user_id=user_id)
            self.session.add(preferences)
            await self.session.flush()
        return preferences

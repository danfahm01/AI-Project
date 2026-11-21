from fastapi import APIRouter, Depends

from app.api.deps import CurrentUser, DbSession, limit_api_requests
from app.schemas.preferences import PreferencesOut, PreferencesUpdate
from app.schemas.user import UserOut, UserUpdate
from app.services.user_service import UserService, preferences_out

router = APIRouter(prefix="/users", tags=["users"], dependencies=[Depends(limit_api_requests)])


@router.get("/me", response_model=UserOut)
async def get_me(user: CurrentUser) -> UserOut:
    return UserOut.model_validate(user)


@router.patch("/me", response_model=UserOut)
async def update_me(body: UserUpdate, user: CurrentUser, session: DbSession) -> UserOut:
    updated = await UserService(session).update_profile(user, body)
    return UserOut.model_validate(updated)


@router.get("/me/preferences", response_model=PreferencesOut)
async def get_preferences(user: CurrentUser, session: DbSession) -> PreferencesOut:
    return preferences_out(await UserService(session).get_preferences(user))


@router.patch("/me/preferences", response_model=PreferencesOut)
async def update_preferences(body: PreferencesUpdate, user: CurrentUser, session: DbSession) -> PreferencesOut:
    return preferences_out(await UserService(session).update_preferences(user, body))

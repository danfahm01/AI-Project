from fastapi import APIRouter, Depends, Request, Response, status

from app.api.deps import DbSession, SettingsDep, limit_auth_requests
from app.schemas.auth import AuthResponse, LoginRequest, LogoutRequest, RefreshRequest, RegisterRequest, TokenPair
from app.schemas.user import UserOut
from app.services.auth_service import AuthService

router = APIRouter(prefix="/auth", tags=["auth"], dependencies=[Depends(limit_auth_requests)])


@router.post("/register", response_model=AuthResponse, status_code=status.HTTP_201_CREATED)
async def register(body: RegisterRequest, request: Request, session: DbSession, settings: SettingsDep) -> AuthResponse:
    user, tokens = await AuthService(session, settings).register(body, user_agent=request.headers.get("user-agent"))
    return AuthResponse(user=UserOut.model_validate(user), tokens=tokens)


@router.post("/login", response_model=AuthResponse)
async def login(body: LoginRequest, request: Request, session: DbSession, settings: SettingsDep) -> AuthResponse:
    user, tokens = await AuthService(session, settings).login(body, user_agent=request.headers.get("user-agent"))
    return AuthResponse(user=UserOut.model_validate(user), tokens=tokens)


@router.post("/refresh", response_model=TokenPair, summary="Rotate the refresh token and issue a new access token")
async def refresh(body: RefreshRequest, request: Request, session: DbSession, settings: SettingsDep) -> TokenPair:
    return await AuthService(session, settings).refresh(
        body.refresh_token, user_agent=request.headers.get("user-agent")
    )


@router.post("/logout", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def logout(body: LogoutRequest, session: DbSession, settings: SettingsDep) -> Response:
    await AuthService(session, settings).logout(body.refresh_token)
    return Response(status_code=status.HTTP_204_NO_CONTENT)

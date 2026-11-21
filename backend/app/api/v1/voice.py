import uuid

from fastapi import APIRouter, Depends, Request, Response, status

from app.api.deps import CurrentUser, DbSession, ProvidersDep, SettingsDep, enforce_rate_limit, limit_api_requests
from app.schemas.message import MessageOut
from app.schemas.voice import TranscriptCreate, VoiceSessionCreate, VoiceSessionOut
from app.services.voice_service import VoiceService

router = APIRouter(prefix="/voice", tags=["voice"], dependencies=[Depends(limit_api_requests)])


@router.post(
    "/sessions",
    response_model=VoiceSessionOut,
    status_code=status.HTTP_201_CREATED,
    summary="Start a realtime voice session (returns a short-lived client secret)",
)
async def create_voice_session(
    body: VoiceSessionCreate,
    request: Request,
    response: Response,
    user: CurrentUser,
    session: DbSession,
    settings: SettingsDep,
    providers: ProvidersDep,
) -> VoiceSessionOut:
    await enforce_rate_limit(request, f"voice:{user.id}", settings.rate_limit_voice_sessions_per_minute)
    result = await VoiceService(session, providers, settings).start(user, body)
    # The body carries a credential: never cache it.
    response.headers["Cache-Control"] = "no-store"
    return result


@router.post(
    "/sessions/{session_id}/transcripts",
    response_model=MessageOut,
    status_code=status.HTTP_201_CREATED,
    summary="Store a finished user or assistant turn of a voice session",
)
async def add_transcript(
    session_id: uuid.UUID,
    body: TranscriptCreate,
    user: CurrentUser,
    session: DbSession,
    settings: SettingsDep,
    providers: ProvidersDep,
) -> MessageOut:
    message = await VoiceService(session, providers, settings).add_transcript(user, session_id, body)
    return MessageOut.from_model(message)


@router.post("/sessions/{session_id}/end", status_code=status.HTTP_204_NO_CONTENT, response_class=Response)
async def end_voice_session(
    session_id: uuid.UUID, user: CurrentUser, session: DbSession, settings: SettingsDep, providers: ProvidersDep
) -> Response:
    await VoiceService(session, providers, settings).end(user, session_id)
    return Response(status_code=status.HTTP_204_NO_CONTENT)

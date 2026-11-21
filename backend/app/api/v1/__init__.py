from fastapi import APIRouter

from app.api.v1 import attachments, auth, chat_socket, conversations, messages, providers, users, voice

api_router = APIRouter()
api_router.include_router(attachments.router)
api_router.include_router(auth.router)
api_router.include_router(chat_socket.router)
api_router.include_router(users.router)
api_router.include_router(conversations.router)
api_router.include_router(messages.router)
api_router.include_router(providers.router)
api_router.include_router(voice.router)

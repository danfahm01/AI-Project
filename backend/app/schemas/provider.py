from pydantic import BaseModel

from app.ai_providers.base import ModelInfo


class ProviderOut(BaseModel):
    id: str
    display_name: str
    is_default: bool
    models: list[ModelInfo]


class ProviderList(BaseModel):
    items: list[ProviderOut]
    default_provider: str | None

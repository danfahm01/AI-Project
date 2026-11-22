from fastapi import APIRouter, Depends

from app.api.deps import ProvidersDep, limit_api_requests
from app.schemas.provider import ProviderList, ProviderOut

router = APIRouter(prefix="/providers", tags=["providers"], dependencies=[Depends(limit_api_requests)])


@router.get("", response_model=ProviderList, summary="AI providers and models available on this server")
async def list_providers(registry: ProvidersDep) -> ProviderList:
    # Picks up models installed since the last check (Ollama), rate limited per provider.
    await registry.refresh()
    # A provider without models (Ollama not running yet) cannot answer: not offered.
    usable = [(provider, provider.list_models()) for provider in registry.list()]
    usable = [(provider, models) for provider, models in usable if models]
    ids = [provider.id for provider, _ in usable]
    default_id = registry.default_id if registry.default_id in ids else (ids[0] if ids else None)
    return ProviderList(
        items=[
            ProviderOut(
                id=provider.id,
                display_name=provider.display_name,
                is_default=provider.id == default_id,
                models=models,
            )
            for provider, models in usable
        ],
        default_provider=default_id,
    )

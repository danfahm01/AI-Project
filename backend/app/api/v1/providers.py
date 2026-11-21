from fastapi import APIRouter, Depends

from app.api.deps import ProvidersDep, limit_api_requests
from app.schemas.provider import ProviderList, ProviderOut

router = APIRouter(prefix="/providers", tags=["providers"], dependencies=[Depends(limit_api_requests)])


@router.get("", response_model=ProviderList, summary="AI providers and models available on this server")
async def list_providers(registry: ProvidersDep) -> ProviderList:
    default_id = registry.default_id
    return ProviderList(
        items=[
            ProviderOut(
                id=provider.id,
                display_name=provider.display_name,
                is_default=provider.id == default_id,
                models=provider.list_models(),
            )
            for provider in registry.list()
        ],
        default_provider=default_id,
    )

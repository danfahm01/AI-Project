import asyncio
import logging
from collections.abc import Iterable

from app.ai_providers.base import AIProvider
from app.core.config import Settings
from app.core.errors import AppError

logger = logging.getLogger(__name__)


class ProviderNotAvailableError(AppError):
    status_code = 404
    code = "provider_not_available"
    default_message = "The requested AI provider is not configured"


class ProviderRegistry:
    """Holds the provider adapters that are configured for this deployment."""

    def __init__(self, providers: Iterable[AIProvider] = (), default_provider: str | None = None) -> None:
        self._providers: dict[str, AIProvider] = {}
        for provider in providers:
            self.register(provider)
        self._default = default_provider

    def register(self, provider: AIProvider) -> None:
        if provider.id in self._providers:
            raise ValueError(f"Provider '{provider.id}' is already registered")
        self._providers[provider.id] = provider

    def get(self, provider_id: str) -> AIProvider:
        try:
            return self._providers[provider_id]
        except KeyError:
            raise ProviderNotAvailableError(f"AI provider '{provider_id}' is not configured") from None

    def list(self) -> list[AIProvider]:
        return list(self._providers.values())

    @property
    def default_id(self) -> str | None:
        if self._default and self._default in self._providers:
            return self._default
        return next(iter(self._providers), None)

    def resolve(self, provider_id: str | None) -> AIProvider:
        """Return the requested provider, or the default one when ``provider_id`` is None."""
        chosen = provider_id or self.default_id
        if chosen is None:
            raise ProviderNotAvailableError("No AI provider is configured on this server")
        return self.get(chosen)

    async def refresh(self, *, force: bool = False) -> None:
        """Let providers whose models change at runtime (Ollama) update their lists."""
        await asyncio.gather(*(provider.refresh(force=force) for provider in self._providers.values()))

    async def aclose(self) -> None:
        for provider in self._providers.values():
            try:
                await provider.aclose()
            except Exception:
                logger.exception("Error while closing provider %s", provider.id)


def build_provider_registry(settings: Settings) -> ProviderRegistry:
    """Create adapters for every provider that has credentials configured."""
    registry = ProviderRegistry(default_provider=settings.default_ai_provider)
    if settings.openai_api_key is not None:
        from app.ai_providers.openai_provider import OpenAIProvider

        registry.register(OpenAIProvider.from_settings(settings))
        logger.info("OpenAI provider enabled with models: %s", ", ".join(settings.openai_models))
    if settings.gemini_api_key is not None:
        from app.ai_providers.gemini_provider import GeminiProvider

        registry.register(GeminiProvider.from_settings(settings))
        logger.info("Gemini provider enabled with models: %s", ", ".join(settings.gemini_models))
    if settings.ollama_base_url is not None:
        from app.ai_providers.ollama_provider import OllamaProvider

        registry.register(OllamaProvider.from_settings(settings))
        logger.info("Ollama provider enabled at %s", settings.ollama_base_url)
    if not registry.list():
        logger.warning(
            "No AI provider configured: set OPENAI_API_KEY, GEMINI_API_KEY or OLLAMA_BASE_URL to enable chat replies"
        )
    return registry

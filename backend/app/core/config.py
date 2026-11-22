"""Application settings loaded from environment variables (and optional .env files)."""

import logging
import secrets
from functools import lru_cache
from typing import Annotated, Any, Literal

from pydantic import Field, SecretStr, field_validator, model_validator
from pydantic_settings import BaseSettings, NoDecode, SettingsConfigDict

logger = logging.getLogger(__name__)

MIN_PRODUCTION_SECRET_LENGTH = 32


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        # Repo-root .env first, backend/.env overrides it.
        env_file=("../.env", ".env"),
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    # --- Application -------------------------------------------------------
    app_name: str = "Voice Assistant API"
    app_env: Literal["development", "test", "production"] = "development"
    log_level: Literal["DEBUG", "INFO", "WARNING", "ERROR"] = "INFO"
    api_v1_prefix: str = "/api/v1"
    enable_api_docs: bool = True

    # --- Persistence ---------------------------------------------------------
    database_url: str = "sqlite+aiosqlite:///./data/dev.db"
    database_echo: bool = False
    # PostgreSQL connection pool, per worker process: workers x (size + overflow)
    # must stay below the server's max_connections (PostgreSQL default: 100).
    database_pool_size: int = Field(default=10, ge=1, le=200)
    database_max_overflow: int = Field(default=10, ge=0, le=200)
    redis_url: str | None = None

    # --- Auth ------------------------------------------------------------------
    jwt_secret: SecretStr = SecretStr("")
    jwt_algorithm: Literal["HS256", "HS384", "HS512"] = "HS256"
    access_token_ttl_minutes: int = Field(default=15, ge=1, le=24 * 60)
    refresh_token_ttl_days: int = Field(default=30, ge=1, le=365)

    # --- HTTP ------------------------------------------------------------------
    cors_origins: Annotated[list[str], NoDecode] = Field(default_factory=list)
    # Allows http(s)://localhost:<any port> — needed for `flutter run -d chrome`,
    # whose dev server picks a random port. Must be false in production.
    cors_allow_localhost: bool = True

    # --- Rate limiting (requests per minute) -----------------------------------
    rate_limit_auth_per_minute: int = Field(default=10, ge=1)
    rate_limit_api_per_minute: int = Field(default=120, ge=1)
    # AI generations (send + regenerate) per user per minute.
    rate_limit_chat_per_minute: int = Field(default=20, ge=1)

    # --- AI providers (server-side only; never sent to clients) ---------------
    openai_api_key: SecretStr | None = None
    # Optional override, e.g. an OpenAI-compatible gateway. Empty = official API.
    openai_base_url: str | None = None
    # Model IDs offered to users. Defaults verified against
    # https://developers.openai.com/api/docs/models on 2026-11-20.
    openai_models: Annotated[list[str], NoDecode] = Field(
        default_factory=lambda: ["gpt-6.2-astra", "gpt-6.2-sol", "gpt-6-luna"]
    )
    openai_default_model: str = "gpt-6.2-astra"
    # Realtime voice (speech-to-speech over WebRTC). Verified on 2026-11-20 against
    # https://developers.openai.com/api/docs/models/gpt-realtime-2.1 and the
    # realtime-conversations guide. Empty model = voice disabled.
    openai_realtime_model: str | None = "gpt-realtime-2.1"
    openai_realtime_voices: Annotated[list[str], NoDecode] = Field(
        default_factory=lambda: [
            "marin",
            "cedar",
            "alloy",
            "ash",
            "ballad",
            "coral",
            "echo",
            "sage",
            "shimmer",
            "verse",
        ]
    )
    openai_realtime_default_voice: str = "marin"
    openai_realtime_transcription_model: str = "gpt-realtime-whisper"

    gemini_api_key: SecretStr | None = None
    # Optional override (e.g. the local test server). Empty = official endpoint.
    gemini_base_url: str | None = None
    # Ephemeral Live API tokens work only with v1beta (live-api/ephemeral-tokens guide).
    gemini_api_version: str = "v1beta"
    # Text models. Verified against https://aistudio.google.com/docs/models on 2026-11-21:
    # Gemini 4 Hydrogen is the recommendation for new projects, Carbon the most capable
    # reasoning model, 3.5 Flash-Lite the low-latency, low-cost option.
    gemini_models: Annotated[list[str], NoDecode] = Field(
        default_factory=lambda: ["gemini-4-hydrogen", "gemini-4-carbon", "gemini-3.5-flash-lite"]
    )
    gemini_default_model: str = "gemini-4-hydrogen"
    # Live API native-audio model (GA 2026-09-15, the default for low-latency voice).
    # Empty = Gemini voice disabled.
    gemini_live_model: str | None = "gemini-3.8-live"
    # Native-audio models accept the prebuilt TTS voices (speech-generation guide).
    gemini_live_voices: Annotated[list[str], NoDecode] = Field(
        default_factory=lambda: [
            "Zephyr",
            "Puck",
            "Charon",
            "Kore",
            "Fenrir",
            "Leda",
            "Orus",
            "Aoede",
            "Callirrhoe",
            "Autonoe",
            "Enceladus",
            "Iapetus",
            "Umbriel",
            "Algieba",
            "Despina",
            "Erinome",
            "Algenib",
            "Rasalgethi",
            "Laomedeia",
            "Achernar",
            "Alnilam",
            "Schedar",
            "Gacrux",
            "Pulcherrima",
            "Achird",
            "Zubenelgenubi",
            "Vindemiatrix",
            "Sadachbia",
            "Sadaltager",
            "Sulafat",
        ]
    )
    gemini_live_default_voice: str = "Kore"

    # Ollama: models that run on this computer, no API key. Empty = disabled; Ollama
    # listens on http://localhost:11434 by default (docs.ollama.com, 2026-11-22).
    # (Not OLLAMA_MODELS or OLLAMA_HOST: Ollama itself reads those.)
    ollama_base_url: str | None = None
    # Installed models offered in the app (comma-separated). Empty = every installed chat model.
    ollama_allowed_models: Annotated[list[str], NoDecode] = Field(default_factory=list)
    ollama_default_model: str | None = None

    default_ai_provider: str | None = None
    ai_request_timeout_seconds: float = Field(default=120, gt=0, le=600)

    # --- Chat behaviour -----------------------------------------------------------
    chat_system_prompt: str = (
        "You are a helpful, accurate assistant. Answer concisely, and use Markdown "
        "(lists, tables, fenced code blocks with a language) when it improves readability."
    )
    chat_max_output_tokens: int | None = Field(default=None, ge=1)
    # Conversation history sent to the model, newest first, until this budget is used.
    chat_history_max_chars: int = Field(default=60_000, ge=1_000)
    # Messages loaded from the database per reply (newest first), so long
    # conversations do not load their whole history for every turn.
    chat_history_max_messages: int = Field(default=200, ge=2, le=10_000)

    # --- Voice --------------------------------------------------------------------
    voice_system_prompt: str = (
        "You are a friendly, helpful voice assistant. Speak naturally and conversationally, "
        "keep answers short unless asked for detail, and never read out Markdown or code formatting."
    )
    # Lifetime of the ephemeral client secret: only needs to cover connection setup.
    voice_token_ttl_seconds: int = Field(default=120, ge=10, le=7200)
    # Longest voice session. Gemini Live tokens stop working after this, including
    # reconnects with session resumption (must be under 20 hours).
    voice_session_max_seconds: int = Field(default=1800, ge=60, le=72_000)
    # Earlier conversation text given to the voice model as context.
    voice_context_max_chars: int = Field(default=6_000, ge=0)
    rate_limit_voice_sessions_per_minute: int = Field(default=6, ge=1)

    # --- Attachments (images and PDFs in chat) -------------------------------------
    # Local directory for uploaded files (a Docker volume in production).
    attachment_storage_dir: str = "./data/attachments"
    # Per file. OpenAI accepts files under 50 MB; Gemini's inline request limit is 20 MB.
    attachment_max_bytes: int = Field(default=10 * 1024 * 1024, ge=1024, le=50 * 1024 * 1024)
    attachments_per_message: int = Field(default=5, ge=1, le=20)
    # Raw bytes of attachments sent with one AI request (base64 adds a third). Newest
    # first; older attachments beyond this are mentioned by name instead.
    attachment_context_max_bytes: int = Field(default=12 * 1024 * 1024, ge=1024)
    # Uploads never sent with a message are deleted after this.
    attachment_pending_ttl_hours: int = Field(default=24, ge=1)
    # Lifetime of signed download links (used to open PDFs in a browser or viewer).
    attachment_link_ttl_seconds: int = Field(default=300, ge=30, le=3600)
    rate_limit_uploads_per_minute: int = Field(default=30, ge=1)

    # --- Web app (one local server without Nginx, see scripts/start-local.ps1) -----
    # Folder with a Flutter web build (API_BASE_URL=/) to serve at /. Empty = API only.
    web_app_dir: str | None = None
    # Hosts the web app connects to directly in voice mode (Content-Security-Policy).
    web_csp_connect_src: str = "https://api.openai.com wss://generativelanguage.googleapis.com"

    @field_validator("log_level", mode="before")
    @classmethod
    def _upper_log_level(cls, value: Any) -> Any:
        return value.upper() if isinstance(value, str) else value

    @field_validator(
        "cors_origins",
        "openai_models",
        "openai_realtime_voices",
        "gemini_models",
        "gemini_live_voices",
        "ollama_allowed_models",
        mode="before",
    )
    @classmethod
    def _split_comma_list(cls, value: Any) -> Any:
        if isinstance(value, str):
            return [item.strip() for item in value.split(",") if item.strip()]
        return value

    @field_validator(
        "redis_url",
        "default_ai_provider",
        "openai_api_key",
        "openai_base_url",
        "openai_realtime_model",
        "gemini_api_key",
        "gemini_base_url",
        "gemini_live_model",
        "ollama_base_url",
        "ollama_default_model",
        "web_app_dir",
        mode="before",
    )
    @classmethod
    def _blank_to_none(cls, value: Any) -> Any:
        if isinstance(value, str) and not value.strip():
            return None
        return value

    @model_validator(mode="after")
    def _enforce_security(self) -> "Settings":
        secret = self.jwt_secret.get_secret_value()
        if self.app_env == "production":
            if len(secret) < MIN_PRODUCTION_SECRET_LENGTH:
                raise ValueError(f"JWT_SECRET must be at least {MIN_PRODUCTION_SECRET_LENGTH} characters in production")
            if self.cors_allow_localhost:
                raise ValueError("CORS_ALLOW_LOCALHOST must be false in production")
            # Browsers must reach the API over HTTPS only.
            insecure_origins = [o for o in self.cors_origins if o == "*" or not o.startswith("https://")]
            if insecure_origins:
                raise ValueError("CORS_ORIGINS must list https:// origins (no '*') in production")
            # The provider API keys travel to these URLs: never over plain HTTP (or to a test server).
            for name, url in (("OPENAI_BASE_URL", self.openai_base_url), ("GEMINI_BASE_URL", self.gemini_base_url)):
                if url is not None and not url.startswith("https://"):
                    raise ValueError(f"{name} must be an https:// URL in production")
            if self.is_sqlite:
                logger.warning("DATABASE_URL points at SQLite; use PostgreSQL in production")
            if self.enable_api_docs:
                logger.warning("API docs are public at /docs; set ENABLE_API_DOCS=false to hide them")
        elif not secret:
            logger.warning(
                "JWT_SECRET is not set; using a random per-process secret. "
                "All sessions become invalid when the server restarts."
            )
            self.jwt_secret = SecretStr(secrets.token_urlsafe(64))
        return self

    @property
    def is_sqlite(self) -> bool:
        return self.database_url.startswith("sqlite")

    @property
    def cors_origin_regex(self) -> str | None:
        if self.cors_allow_localhost:
            return r"^https?://(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$"
        return None


@lru_cache
def get_settings() -> Settings:
    return Settings()

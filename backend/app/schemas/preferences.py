from datetime import datetime
from typing import Annotated

from pydantic import BaseModel, Field, StringConstraints, model_validator

from app.models.preferences import ThemeMode, VoiceMode
from app.schemas.common import APIModel, ModelId, ProviderId, RequestModel

# BCP 47 language tag, e.g. "en", "en-US", "id-ID", "zh-Hant-TW".
LanguageTag = Annotated[
    str, StringConstraints(strip_whitespace=True, max_length=35, pattern=r"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$")
]
VoiceName = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=100)]


class AudioSettings(BaseModel):
    """Capture processing flags passed to the platform audio stack."""

    echo_cancellation: bool = True
    noise_suppression: bool = True
    auto_gain_control: bool = True


class PreferencesOut(APIModel):
    theme: ThemeMode
    language: str | None
    default_provider: str | None
    default_model: str | None
    voice_provider: str | None
    voice_model: str | None
    voice_name: str | None
    speaking_rate: float | None
    auto_speech_detection: bool
    voice_mode: VoiceMode
    audio_settings: AudioSettings
    updated_at: datetime


class PreferencesUpdate(RequestModel):
    """Partial update: only fields present in the request body are changed.

    Sending ``null`` clears an optional field (falls back to the provider default).
    """

    theme: ThemeMode | None = None
    language: LanguageTag | None = None
    default_provider: ProviderId | None = None
    default_model: ModelId | None = None
    # Realtime voice model; an unavailable choice falls back to the server default.
    voice_provider: ProviderId | None = None
    voice_model: ModelId | None = None
    # Voice IDs are provider-specific; an unknown one falls back to the model's default.
    voice_name: VoiceName | None = None
    # The widest range any supported provider accepts; each provider clamps it
    # to its own documented range (models without a rate parameter ignore it).
    speaking_rate: Annotated[float, Field(ge=0.25, le=4.0)] | None = None
    auto_speech_detection: bool | None = None
    voice_mode: VoiceMode | None = None
    audio_settings: AudioSettings | None = None  # null resets to defaults

    @model_validator(mode="after")
    def _non_nullable(self) -> "PreferencesUpdate":
        for name in ("theme", "auto_speech_detection", "voice_mode"):
            if name in self.model_fields_set and getattr(self, name) is None:
                raise ValueError(f"{name} cannot be null")
        return self

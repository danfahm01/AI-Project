from typing import Annotated

from pydantic import BaseModel, ConfigDict, StringConstraints


class APIModel(BaseModel):
    model_config = ConfigDict(from_attributes=True)


class RequestModel(BaseModel):
    """Request bodies reject unknown fields so typos surface as 422s."""

    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


ProviderId = Annotated[
    str, StringConstraints(strip_whitespace=True, min_length=1, max_length=50, pattern=r"^[a-z0-9_\-]+$")
]
ModelId = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=100)]

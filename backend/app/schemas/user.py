import uuid
from datetime import datetime
from typing import Annotated

from pydantic import StringConstraints

from app.schemas.common import APIModel, RequestModel

DisplayName = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=100)]


class UserOut(APIModel):
    id: uuid.UUID
    email: str
    display_name: str
    created_at: datetime


class UserUpdate(RequestModel):
    display_name: DisplayName

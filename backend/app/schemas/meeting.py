from datetime import datetime, timezone
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator, field_serializer
from typing_extensions import Self


class MeetingBase(BaseModel):
    title: str = Field(..., description="Meeting title")
    starts_at: datetime = Field(..., description="Start timestamp in UTC")
    ends_at: datetime = Field(..., description="End timestamp in UTC")
    attendee_count: int = Field(..., ge=0, description="Non-negative attendee count")

    @field_validator("title")
    @classmethod
    def validate_title(cls, v: str) -> str:
        if not v or not v.strip():
            raise ValueError("title is required and non-empty")
        return v.strip()

    @field_validator("starts_at", "ends_at")
    @classmethod
    def ensure_utc(cls, v: datetime) -> datetime:
        if v.tzinfo is None:
            return v.replace(tzinfo=timezone.utc)
        return v.astimezone(timezone.utc)

    @model_validator(mode="after")
    def validate_time_order(self) -> Self:
        if self.starts_at >= self.ends_at:
            raise ValueError("starts_at must be earlier than ends_at")
        return self


class MeetingCreate(MeetingBase):
    pass


class MeetingResponse(MeetingBase):
    id: int

    model_config = ConfigDict(from_attributes=True)

    @field_serializer("starts_at", "ends_at")
    def serialize_dt(self, dt: datetime, _info) -> str:
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=timezone.utc)
        else:
            dt = dt.astimezone(timezone.utc)
        return dt.strftime("%Y-%m-%dT%H:%M:%SZ")

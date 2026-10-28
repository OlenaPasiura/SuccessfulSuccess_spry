import os
from datetime import UTC, date, datetime
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, status
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.ai.agenda import DEFAULT_MODEL, PROMPT_VERSION, AgendaParseError, parse_agenda
from app.db import get_db
from app.schemas.meeting import MeetingCreate, MeetingResponse
from app.services import meetings as meeting_service

router = APIRouter(tags=["meetings"])


class AgendaParseRequest(BaseModel):
    text: str
    today: str | None = None
    tz: str = "UTC"


@router.get("/api/meetings", response_model=list[MeetingResponse], status_code=status.HTTP_200_OK)
def list_meetings(db: Session = Depends(get_db)) -> list[MeetingResponse]:
    return meeting_service.get_meetings(db)


@router.post("/api/meetings", response_model=MeetingResponse, status_code=status.HTTP_201_CREATED)
def create_meeting(meeting_in: MeetingCreate, db: Session = Depends(get_db)) -> MeetingResponse:
    return meeting_service.create_meeting(db, meeting_in)


@router.put(
    "/api/meetings/{meeting_id}", response_model=MeetingResponse, status_code=status.HTTP_200_OK
)
def update_meeting(
    meeting_id: int, meeting_in: MeetingCreate, db: Session = Depends(get_db)
) -> MeetingResponse:
    updated = meeting_service.update_meeting(db, meeting_id, meeting_in)
    if updated is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Meeting not found")
    return updated


@router.post("/api/agenda/parse", status_code=status.HTTP_200_OK)
def parse_meeting_agenda(payload: AgendaParseRequest) -> dict[str, Any]:
    if not payload.text or not payload.text.strip():
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content={"error": "Field 'text' is required and must be a non-empty string"},
        )
    if len(payload.text) > 10_000:
        return JSONResponse(
            status_code=status.HTTP_413_REQUEST_ENTITY_TOO_LARGE,
            content={"error": "Input text exceeds maximum length of 10000 characters"},
        )
    try:
        resolved_today = (
            date.fromisoformat(payload.today) if payload.today else datetime.now(UTC).date()
        )
    except ValueError:
        return JSONResponse(
            status_code=status.HTTP_400_BAD_REQUEST,
            content={"error": "Field 'today' must be an ISO date string (YYYY-MM-DD)"},
        )

    model = os.getenv("PARSER_MODEL", DEFAULT_MODEL)
    try:
        agenda, _usage = parse_agenda(
            text=payload.text, today=resolved_today, tz=payload.tz, model_id=model
        )
    except AgendaParseError as err:
        return JSONResponse(
            status_code=status.HTTP_422_UNPROCESSABLE_ENTITY,
            content={"error": str(err)},
        )

    return {
        "agenda": agenda.model_dump(mode="json"),
        "model": model,
        "prompt_version": PROMPT_VERSION,
    }

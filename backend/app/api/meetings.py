from fastapi import APIRouter, Depends, status
from sqlalchemy.orm import Session

from app.db import get_db
from app.schemas.meeting import MeetingCreate, MeetingResponse
from app.services import meetings as meeting_service

router = APIRouter(tags=["meetings"])


@router.get("/api/meetings", response_model=list[MeetingResponse], status_code=status.HTTP_200_OK)
def list_meetings(db: Session = Depends(get_db)) -> list[MeetingResponse]:
    return meeting_service.get_meetings(db)


@router.post("/api/meetings", response_model=MeetingResponse, status_code=status.HTTP_201_CREATED)
def create_meeting(meeting_in: MeetingCreate, db: Session = Depends(get_db)) -> MeetingResponse:
    return meeting_service.create_meeting(db, meeting_in)

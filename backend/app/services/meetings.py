from typing import List
from sqlalchemy.orm import Session
from app.models.meeting import Meeting
from app.schemas.meeting import MeetingCreate


def get_meetings(db: Session) -> List[Meeting]:
    return db.query(Meeting).order_by(Meeting.starts_at.asc(), Meeting.id.asc()).all()


def create_meeting(db: Session, meeting_in: MeetingCreate) -> Meeting:
    meeting = Meeting(
        title=meeting_in.title,
        starts_at=meeting_in.starts_at,
        ends_at=meeting_in.ends_at,
        attendee_count=meeting_in.attendee_count,
    )
    db.add(meeting)
    db.commit()
    db.refresh(meeting)
    return meeting

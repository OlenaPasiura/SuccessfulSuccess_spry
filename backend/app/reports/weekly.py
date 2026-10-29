"""Weekly meeting CSV report generator for event-driven architecture."""

import csv
import io
import re
import sys
from datetime import UTC, date, datetime, time, timedelta

from sqlalchemy.orm import Session

from app.db import SessionLocal
from app.models.meeting import Meeting

ISO_WEEK_REGEX = re.compile(r"^(\d{4})-[Ww](\d{1,2})$")


def parse_iso_week(
    week_str: str,
) -> tuple[datetime, datetime, datetime, datetime, str, str, date, date, date, date]:
    """Parse an ISO week string (e.g. '2026-W40') into UTC datetime boundaries.

    Returns:
        tuple containing:
            - current_start_dt (Monday 00:00:00 UTC)
            - current_end_dt (Next Monday 00:00:00 UTC, exclusive)
            - prev_start_dt (Prev Monday 00:00:00 UTC)
            - prev_end_dt (Prev Sunday 23:59:59.999999 / Monday 00:00:00 UTC, exclusive)
            - normalized_current_week (e.g. '2026-W40')
            - normalized_prev_week (e.g. '2026-W39')
            - current_monday_date
            - current_sunday_date
            - prev_monday_date
            - prev_sunday_date
    """
    if not isinstance(week_str, str):
        raise ValueError(f"Week must be a string, got {type(week_str).__name__}")

    cleaned = week_str.strip()
    match = ISO_WEEK_REGEX.match(cleaned)
    if not match:
        raise ValueError(
            f"Invalid ISO week format '{week_str}'. Expected format 'YYYY-Www' (e.g. '2026-W40')."
        )

    year = int(match.group(1))
    week_num = int(match.group(2))

    try:
        current_monday = date.fromisocalendar(year, week_num, 1)
        current_sunday = date.fromisocalendar(year, week_num, 7)
    except ValueError as err:
        raise ValueError(f"Invalid ISO week '{week_str}': {err}") from err

    current_start_dt = datetime.combine(current_monday, time.min, tzinfo=UTC)
    current_end_dt = current_start_dt + timedelta(days=7)

    prev_monday = current_monday - timedelta(days=7)
    prev_sunday = current_sunday - timedelta(days=7)
    prev_start_dt = current_start_dt - timedelta(days=7)
    prev_end_dt = current_start_dt

    prev_iso = prev_monday.isocalendar()
    prev_week_str = f"{prev_iso.year}-W{prev_iso.week:02d}"
    current_week_str = f"{year}-W{week_num:02d}"

    return (
        current_start_dt,
        current_end_dt,
        prev_start_dt,
        prev_end_dt,
        current_week_str,
        prev_week_str,
        current_monday,
        current_sunday,
        prev_monday,
        prev_sunday,
    )


def _get_meeting_duration_hours(meeting: Meeting) -> float:
    """Calculate the meeting duration in hours, ensuring non-negative value."""
    if not meeting.starts_at or not meeting.ends_at:
        return 0.0
    delta = (meeting.ends_at - meeting.starts_at).total_seconds()
    return max(0.0, delta / 3600.0)


def _generate_weekly_report(week: str, db: Session) -> bytes:
    (
        curr_start_dt,
        curr_end_dt,
        prev_start_dt,
        prev_end_dt,
        curr_week_label,
        prev_week_label,
        curr_monday,
        curr_sunday,
        prev_monday,
        prev_sunday,
    ) = parse_iso_week(week)

    # 1. Query meetings for current week
    current_meetings = (
        db.query(Meeting)
        .filter(Meeting.starts_at >= curr_start_dt, Meeting.starts_at < curr_end_dt)
        .all()
    )

    # 2. Query meetings for previous week
    prev_meetings = (
        db.query(Meeting)
        .filter(Meeting.starts_at >= prev_start_dt, Meeting.starts_at < prev_end_dt)
        .all()
    )

    # 3. Aggregate metrics
    curr_count = len(current_meetings)
    curr_total_hours = sum(_get_meeting_duration_hours(m) for m in current_meetings)

    prev_count = len(prev_meetings)
    prev_total_hours = sum(_get_meeting_duration_hours(m) for m in prev_meetings)

    count_change = curr_count - prev_count
    hours_change = curr_total_hours - prev_total_hours

    formatted_count_change = f"+{count_change}" if count_change > 0 else str(count_change)
    formatted_hours_change = f"+{hours_change:.2f}" if hours_change > 0 else f"{hours_change:.2f}"

    # 4. Top 5 longest meetings of the current week
    # Sort primarily by duration descending, then start time ascending, then id
    def sort_key(m: Meeting):
        dur = (m.ends_at - m.starts_at).total_seconds() if m.starts_at and m.ends_at else 0.0
        start_ts = m.starts_at.timestamp() if m.starts_at else 0.0
        return (dur, -start_ts, -(m.id or 0))

    top_5_meetings = sorted(current_meetings, key=sort_key, reverse=True)[:5]

    # 5. Build formatted CSV output
    output = io.StringIO()
    writer = csv.writer(output, lineterminator="\n")

    # Header / Meta
    writer.writerow(["Weekly Meeting Report", curr_week_label])
    writer.writerow(["Period", f"{curr_monday.isoformat()} to {curr_sunday.isoformat()}"])
    prev_period_desc = f"{prev_week_label} ({prev_monday.isoformat()} to {prev_sunday.isoformat()})"
    writer.writerow(["Previous Week", prev_period_desc])
    writer.writerow([])

    # Summary Statistics
    summary_header = [
        "Metric",
        f"Current Week ({curr_week_label})",
        f"Previous Week ({prev_week_label})",
        "Change",
    ]
    writer.writerow(summary_header)
    writer.writerow(["Meeting Count", str(curr_count), str(prev_count), formatted_count_change])
    writer.writerow(
        [
            "Total Duration (hours)",
            f"{curr_total_hours:.2f}",
            f"{prev_total_hours:.2f}",
            formatted_hours_change,
        ]
    )
    writer.writerow([])

    # Top 5 Longest Meetings
    writer.writerow(["Top 5 Longest Meetings"])
    writer.writerow(["Rank", "Title", "Start Time", "Duration (hours)", "Participant Count"])

    for rank, m in enumerate(top_5_meetings, start=1):
        start_str = m.starts_at.isoformat() if m.starts_at else ""
        dur_hours_str = f"{_get_meeting_duration_hours(m):.2f}"
        writer.writerow([rank, m.title, start_str, dur_hours_str, m.attendee_count])

    return output.getvalue().encode("utf-8")


def build_weekly_report(week: str, db: Session | None = None) -> bytes:
    """Generate weekly meeting report as UTF-8 encoded CSV bytes.

    Args:
        week: ISO week string, e.g. '2026-W40'.
        db: Optional SQLAlchemy Session. If not provided, a new session is
            created from SessionLocal and closed upon completion.

    Returns:
        UTF-8 encoded CSV document bytes.
    """
    if db is not None:
        return _generate_weekly_report(week, db)

    with SessionLocal() as session:
        return _generate_weekly_report(week, session)


def _escape_pdf_text(text: str) -> str:
    ascii_text = text.encode("ascii", errors="replace").decode("ascii")
    return ascii_text.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def _build_pdf_from_lines(lines: list[str]) -> bytes:
    content_cmds = ["BT", "/F1 16 Tf", "50 760 Td"]
    for idx, line in enumerate(lines):
        if idx == 1:
            content_cmds.append("/F1 10 Tf")
            content_cmds.append("0 -22 Td")
        elif idx > 1:
            content_cmds.append("0 -16 Td")
        content_cmds.append(f"({_escape_pdf_text(line)}) Tj")
    content_cmds.append("ET")
    stream_bytes = "\n".join(content_cmds).encode("ascii")

    objects = [
        b"1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n",
        b"2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n",
        (
            b"3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
            b"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>\nendobj\n"
        ),
        b"4 0 obj\n<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>\nendobj\n",
        f"5 0 obj\n<< /Length {len(stream_bytes)} >>\nstream\n".encode("ascii")
        + stream_bytes
        + b"\nendstream\nendobj\n",
    ]

    pdf = bytearray(b"%PDF-1.4\n")
    offsets: list[int] = []
    for obj in objects:
        offsets.append(len(pdf))
        pdf.extend(obj)

    xref_pos = len(pdf)
    pdf.extend(f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode("ascii"))
    for off in offsets:
        pdf.extend(f"{off:010d} 00000 n \n".encode("ascii"))
    trailer = f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref_pos}\n%%EOF\n"
    pdf.extend(trailer.encode("ascii"))
    return bytes(pdf)


def build_weekly_report_pdf(week: str, db: Session | None = None) -> bytes:
    """Generate weekly meeting report as a valid PDF document."""
    csv_text = build_weekly_report(week, db=db).decode("utf-8")
    reader = csv.reader(io.StringIO(csv_text))
    lines: list[str] = []
    for row in reader:
        if not row:
            lines.append("")
        else:
            lines.append(" | ".join(row))
    return _build_pdf_from_lines(lines)


if __name__ == "__main__":
    week_arg = sys.argv[1] if len(sys.argv) > 1 else "2026-W40"
    report_bytes = build_weekly_report(week_arg)
    sys.stdout.buffer.write(report_bytes)

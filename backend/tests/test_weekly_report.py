import csv
import io
from datetime import UTC, datetime

import pytest

from app.models.meeting import Meeting
from app.reports.weekly import build_weekly_report, parse_iso_week


def test_parse_iso_week_valid():
    """Verify ISO week parsing for regular week and year boundaries."""
    # 2026-W40: Monday Sep 28 to Sunday Oct 04, 2026
    (
        curr_start,
        curr_end,
        prev_start,
        prev_end,
        curr_label,
        prev_label,
        curr_m,
        curr_s,
        prev_m,
        prev_s,
    ) = parse_iso_week("2026-W40")
    assert curr_label == "2026-W40"
    assert prev_label == "2026-W39"
    assert curr_m.isoformat() == "2026-09-28"
    assert curr_s.isoformat() == "2026-10-04"
    assert prev_m.isoformat() == "2026-09-21"
    assert prev_s.isoformat() == "2026-09-27"
    assert curr_start == datetime(2026, 9, 28, 0, 0, tzinfo=UTC)
    assert curr_end == datetime(2026, 10, 5, 0, 0, tzinfo=UTC)


def test_parse_iso_week_year_boundary():
    """Verify ISO week parsing across year boundary (2026-W01 previous week is 2025-W52)."""
    (
        curr_start,
        curr_end,
        prev_start,
        prev_end,
        curr_label,
        prev_label,
        curr_m,
        curr_s,
        prev_m,
        prev_s,
    ) = parse_iso_week("2026-W01")
    assert curr_label == "2026-W01"
    assert prev_label == "2025-W52"
    assert curr_m.isoformat() == "2025-12-29"
    assert prev_m.isoformat() == "2025-12-22"


def test_parse_iso_week_invalid():
    """Verify that invalid week format or invalid week number raises ValueError."""
    with pytest.raises(ValueError, match="Invalid ISO week format"):
        parse_iso_week("invalid-week")

    with pytest.raises(ValueError, match="Invalid ISO week format"):
        parse_iso_week("2026-10-05")

    with pytest.raises(ValueError, match="Invalid ISO week"):
        parse_iso_week("2026-W99")


def test_build_weekly_report_calculation(db_session):
    """Verify accurate aggregation of meetings, previous week change, and top 5 ordering."""
    # Previous week (2026-W39: Sep 21 - Sep 27): 2 meetings, 3.5 total hours
    m_prev1 = Meeting(
        title="Prev Standup",
        starts_at=datetime(2026, 9, 22, 9, 0, tzinfo=UTC),
        ends_at=datetime(2026, 9, 22, 10, 30, tzinfo=UTC),  # 1.5h
        attendee_count=4,
    )
    m_prev2 = Meeting(
        title="Prev Sprint Planning",
        starts_at=datetime(2026, 9, 24, 14, 0, tzinfo=UTC),
        ends_at=datetime(2026, 9, 24, 16, 0, tzinfo=UTC),  # 2.0h
        attendee_count=6,
    )

    # Current week (2026-W40: Sep 28 - Oct 04): 6 meetings with varying durations
    meetings_w40 = [
        Meeting(
            title="Short Sync",
            starts_at=datetime(2026, 9, 28, 10, 0, tzinfo=UTC),
            ends_at=datetime(2026, 9, 28, 10, 30, tzinfo=UTC),  # 0.5h
            attendee_count=2,
        ),
        Meeting(
            title="Team All-Hands",
            starts_at=datetime(2026, 9, 29, 11, 0, tzinfo=UTC),
            ends_at=datetime(2026, 9, 29, 12, 0, tzinfo=UTC),  # 1.0h
            attendee_count=20,
        ),
        Meeting(
            title="Architecture Deep Dive",
            starts_at=datetime(2026, 9, 30, 14, 0, tzinfo=UTC),
            ends_at=datetime(2026, 9, 30, 17, 0, tzinfo=UTC),  # 3.0h
            attendee_count=5,
        ),
        Meeting(
            title="Sprint Review",
            starts_at=datetime(2026, 10, 1, 15, 0, tzinfo=UTC),
            ends_at=datetime(2026, 10, 1, 17, 30, tzinfo=UTC),  # 2.5h
            attendee_count=10,
        ),
        Meeting(
            title="1-on-1 Sync",
            starts_at=datetime(2026, 10, 2, 9, 0, tzinfo=UTC),
            ends_at=datetime(2026, 10, 2, 9, 45, tzinfo=UTC),  # 0.75h
            attendee_count=2,
        ),
        Meeting(
            title="Workshop",
            starts_at=datetime(2026, 10, 2, 13, 0, tzinfo=UTC),
            ends_at=datetime(2026, 10, 2, 15, 0, tzinfo=UTC),  # 2.0h
            attendee_count=8,
        ),
    ]

    # Future week meeting (2026-W41) - should NOT be included
    m_future = Meeting(
        title="Future Meeting",
        starts_at=datetime(2026, 10, 6, 10, 0, tzinfo=UTC),
        ends_at=datetime(2026, 10, 6, 12, 0, tzinfo=UTC),
        attendee_count=3,
    )

    db_session.add_all([m_prev1, m_prev2, m_future] + meetings_w40)
    db_session.commit()

    report_bytes = build_weekly_report("2026-W40", db=db_session)
    assert isinstance(report_bytes, bytes)

    content = report_bytes.decode("utf-8")
    reader = list(csv.reader(io.StringIO(content)))

    # Verify Summary Rows
    # Expected: 6 meetings (curr), 2 (prev), change: +4
    # Expected hours: 0.5 + 1.0 + 3.0 + 2.5 + 0.75 + 2.0 = 9.75 hours (curr),
    # 3.50 (prev), change: +6.25
    count_row = next(r for r in reader if r and r[0] == "Meeting Count")
    assert count_row[1] == "6"
    assert count_row[2] == "2"
    assert count_row[3] == "+4"

    hours_row = next(r for r in reader if r and r[0] == "Total Duration (hours)")
    assert hours_row[1] == "9.75"
    assert hours_row[2] == "3.50"
    assert hours_row[3] == "+6.25"

    # Verify Top 5 Longest Meetings ordering
    # Top 5 in descending order of duration:
    # 1. Architecture Deep Dive (3.00h)
    # 2. Sprint Review (2.50h)
    # 3. Workshop (2.00h)
    # 4. Team All-Hands (1.00h)
    # 5. 1-on-1 Sync (0.75h)
    # (Short Sync 0.50h should be excluded from top 5)
    header_idx = next(i for i, r in enumerate(reader) if r and r[0] == "Top 5 Longest Meetings")
    col_names = reader[header_idx + 1]
    assert col_names == ["Rank", "Title", "Start Time", "Duration (hours)", "Participant Count"]

    top_rows = reader[header_idx + 2 : header_idx + 7]
    assert len(top_rows) == 5

    assert top_rows[0][1] == "Architecture Deep Dive"
    assert top_rows[0][3] == "3.00"
    assert top_rows[0][4] == "5"

    assert top_rows[1][1] == "Sprint Review"
    assert top_rows[1][3] == "2.50"
    assert top_rows[1][4] == "10"

    assert top_rows[2][1] == "Workshop"
    assert top_rows[2][3] == "2.00"

    assert top_rows[3][1] == "Team All-Hands"
    assert top_rows[3][3] == "1.00"

    assert top_rows[4][1] == "1-on-1 Sync"
    assert top_rows[4][3] == "0.75"


def test_build_weekly_report_empty_week(db_session):
    """Verify report output for a week with 0 meetings."""
    report_bytes = build_weekly_report("2026-W15", db=db_session)
    content = report_bytes.decode("utf-8")
    reader = list(csv.reader(io.StringIO(content)))

    count_row = next(r for r in reader if r and r[0] == "Meeting Count")
    assert count_row[1] == "0"
    assert count_row[2] == "0"
    assert count_row[3] == "0"

    hours_row = next(r for r in reader if r and r[0] == "Total Duration (hours)")
    assert hours_row[1] == "0.00"
    assert hours_row[2] == "0.00"
    assert hours_row[3] == "0.00"


def test_build_weekly_report_default_session():
    """Verify build_weekly_report without explicit db argument runs against default SessionLocal."""
    report_bytes = build_weekly_report("2026-W40")
    assert isinstance(report_bytes, bytes)
    content = report_bytes.decode("utf-8")
    assert "Weekly Meeting Report,2026-W40" in content
    assert "Meeting Count" in content
    assert "Top 5 Longest Meetings" in content

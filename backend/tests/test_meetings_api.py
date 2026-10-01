def test_get_meetings_empty(client):
    response = client.get("/api/meetings")
    assert response.status_code == 200
    assert response.json() == []


def test_create_meeting_success(client):
    payload = {
        "title": "Architecture Review",
        "starts_at": "2026-10-01T14:00:00Z",
        "ends_at": "2026-10-01T15:00:00Z",
        "attendee_count": 3,
    }
    response = client.post("/api/meetings", json=payload)
    assert response.status_code == 201
    data = response.json()
    assert data["id"] is not None
    assert data["title"] == "Architecture Review"
    assert data["starts_at"] == "2026-10-01T14:00:00Z"
    assert data["ends_at"] == "2026-10-01T15:00:00Z"
    assert data["attendee_count"] == 3

    # Check that it shows up in GET /api/meetings
    get_res = client.get("/api/meetings")
    assert get_res.status_code == 200
    meetings = get_res.json()
    assert len(meetings) == 1
    assert meetings[0]["id"] == data["id"]
    assert meetings[0]["title"] == "Architecture Review"


def test_create_meeting_invalid_title(client):
    payload = {
        "title": "   ",
        "starts_at": "2026-10-01T14:00:00Z",
        "ends_at": "2026-10-01T15:00:00Z",
        "attendee_count": 3,
    }
    response = client.post("/api/meetings", json=payload)
    assert response.status_code == 422


def test_create_meeting_invalid_time_order(client):
    payload = {
        "title": "Invalid Times",
        "starts_at": "2026-10-01T16:00:00Z",
        "ends_at": "2026-10-01T15:00:00Z",
        "attendee_count": 3,
    }
    response = client.post("/api/meetings", json=payload)
    assert response.status_code == 422


def test_create_meeting_negative_attendee_count(client):
    payload = {
        "title": "Negative Attendees",
        "starts_at": "2026-10-01T14:00:00Z",
        "ends_at": "2026-10-01T15:00:00Z",
        "attendee_count": -1,
    }
    response = client.post("/api/meetings", json=payload)
    assert response.status_code == 422

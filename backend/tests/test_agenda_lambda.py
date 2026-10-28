"""Unit tests for the Agenda Parser Lambda handler (Step 3, Lab 5)."""

import json
import logging
from datetime import date
from unittest.mock import patch

import pytest

from app.ai.agenda import ActionItem, AgendaItem, AgendaParseError, ParsedAgenda
from app.ai.agenda_lambda import cost_usd, handler


def test_cost_usd_sonnet():
    usage = {"input_tokens": 1000, "output_tokens": 1000}
    assert cost_usd("us.anthropic.claude-sonnet-4-6", usage) == pytest.approx(0.018)


def test_cost_usd_haiku():
    usage = {"input_tokens": 2000, "output_tokens": 1000}
    assert cost_usd("us.anthropic.claude-haiku-4-5-20251001-v1:0", usage) == pytest.approx(0.007)


def test_handler_missing_auth_returns_401():
    event = {
        "headers": {},
        "body": json.dumps({"text": "Meeting tomorrow", "today": "2026-10-28", "tz": "UTC"}),
    }
    resp = handler(event)
    assert resp["statusCode"] == 401


@patch("app.ai.agenda_lambda.verify_cognito_token", side_effect=ValueError("Invalid signature"))
def test_handler_invalid_jwt_returns_401(_mock_verify):
    event = {
        "headers": {"authorization": "Bearer invalid.jwt.token"},
        "body": json.dumps({"text": "Meeting tomorrow", "today": "2026-10-28", "tz": "UTC"}),
    }
    resp = handler(event)
    assert resp["statusCode"] == 401


@patch("app.ai.agenda_lambda.verify_cognito_token", return_value={"sub": "user-123"})
def test_handler_text_too_long_returns_413(_mock_verify):
    event = {
        "headers": {"Authorization": "Bearer valid.jwt.token"},
        "body": json.dumps(
            {
                "text": "x" * 10_001,
                "today": "2026-10-28",
                "tz": "Europe/Kyiv",
            }
        ),
    }
    resp = handler(event)
    assert resp["statusCode"] == 413


@patch("app.ai.agenda_lambda.verify_cognito_token", return_value={"sub": "user-123"})
@patch(
    "app.ai.agenda_lambda.parse_agenda",
    side_effect=AgendaParseError("the model returned an invalid agenda twice"),
)
def test_handler_parse_error_returns_422(_mock_parse, _mock_verify):
    event = {
        "headers": {"Authorization": "Bearer valid.jwt.token"},
        "body": json.dumps(
            {
                "text": "Unparseable content",
                "today": "2026-10-28",
                "tz": "Europe/Kyiv",
            }
        ),
    }
    resp = handler(event)
    assert resp["statusCode"] == 422
    payload = json.loads(resp["body"])
    assert "invalid agenda twice" in payload["error"]


@patch("app.ai.agenda_lambda.verify_cognito_token", return_value={"sub": "user-123"})
@patch("app.ai.agenda_lambda.parse_agenda")
def test_handler_success_returns_200_and_logs_metrics(mock_parse, _mock_verify, caplog):
    sample_agenda = ParsedAgenda(
        title="Team Sync",
        starts_at="2026-11-02T10:00:00+02:00",
        duration_minutes=45,
        items=[AgendaItem(topic="Q4 roadmap", owner="Olena", minutes=20)],
        action_items=[ActionItem(task="Send slides", owner="Olena", due=date(2026, 10, 30))],
        language="English",
    )
    mock_parse.return_value = (sample_agenda, {"input_tokens": 1200, "output_tokens": 200})

    event = {
        "headers": {"authorization": "Bearer valid.jwt.token"},
        "body": json.dumps(
            {
                "text": "Team sync on Monday at 10:00 (45m).",
                "today": "2026-10-28",
                "tz": "Europe/Kyiv",
            }
        ),
    }

    with caplog.at_level(logging.INFO, logger="agenda-parser"):
        resp = handler(event)

    assert resp["statusCode"] == 200
    body = json.loads(resp["body"])
    assert body["agenda"]["title"] == "Team Sync"
    assert body["agenda"]["duration_minutes"] == 45
    assert body["prompt_version"] == "agenda-v1"
    assert "model" in body

    assert len(caplog.records) >= 1
    logged = json.loads(caplog.records[-1].message)
    assert logged["user"] == "user-123"
    assert logged["prompt_version"] == "agenda-v1"
    assert logged["input_tokens"] == 1200
    assert logged["output_tokens"] == 200
    assert isinstance(logged["latency_ms"], int)
    assert logged["cost_usd"] == pytest.approx((1200 * 0.003 + 200 * 0.015) / 1000.0)

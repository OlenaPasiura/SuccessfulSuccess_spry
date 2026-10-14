"""Tests for weekly report Lambda handler and trigger detection."""

import json
import os
import re
from unittest.mock import MagicMock, patch

from app.reports.lambda_handler import detect_trigger, get_previous_iso_week, handler


def test_detect_trigger():
    assert detect_trigger({"source": "schedule"}) == "schedule"
    assert detect_trigger({"source": "custom.app"}) == "custom.app"
    assert detect_trigger({}) == "manual"
    assert detect_trigger(None) == "manual"
    assert detect_trigger("not-a-dict") == "manual"
    assert detect_trigger({"Records": [{"eventSource": "aws:sqs"}]}) == "sqs"
    assert detect_trigger({"Records": [{"eventSource": "sqs"}]}) == "sqs"
    assert detect_trigger({"Records": [{"EventSource": "aws:s3"}]}) == "aws:s3"
    assert detect_trigger({"detail-type": "Scheduled Event"}) == "Scheduled Event"
    assert detect_trigger({"requestContext": {}}) == "api"


def test_get_previous_iso_week_format():
    week = get_previous_iso_week()
    assert re.match(r"^\d{4}-W\d{2}$", week)


@patch.dict(os.environ, {"REPORTS_BUCKET_NAME": "test-reports-bucket"})
@patch("boto3.client")
def test_handler_direct_invocation(mock_boto_client):
    mock_s3 = MagicMock()
    mock_boto_client.return_value = mock_s3

    event = {"source": "schedule", "week": "2026-W40"}
    result = handler(event)

    assert result["statusCode"] == 200
    assert result["bucket"] == "test-reports-bucket"
    assert result["key"] == "reports/2026-W40.csv"
    assert result["week"] == "2026-W40"
    assert result["size_bytes"] > 0

    mock_boto_client.assert_called_with("s3")
    mock_s3.put_object.assert_called_once()
    call_kwargs = mock_s3.put_object.call_args.kwargs
    assert call_kwargs["Bucket"] == "test-reports-bucket"
    assert call_kwargs["Key"] == "reports/2026-W40.csv"
    assert call_kwargs["ContentType"] == "text/csv"
    assert isinstance(call_kwargs["Body"], bytes)


@patch.dict(os.environ, {"REPORTS_BUCKET_NAME": "test-reports-bucket"})
@patch("boto3.client")
def test_handler_sqs_invocation_on_demand(mock_boto_client):
    mock_s3 = MagicMock()
    mock_boto_client.return_value = mock_s3

    sqs_event = {
        "Records": [
            {
                "messageId": "msg-12345",
                "receiptHandle": "handle-12345",
                "body": json.dumps({"week": "2026-W39", "source": "on-demand"}),
                "eventSource": "aws:sqs",
            }
        ]
    }
    result = handler(sqs_event)

    assert result["statusCode"] == 200
    assert result["bucket"] == "test-reports-bucket"
    assert result["key"] == "reports/2026-W39.csv"
    assert result["week"] == "2026-W39"
    assert result["size_bytes"] > 0

    mock_s3.put_object.assert_called_once()
    call_kwargs = mock_s3.put_object.call_args.kwargs
    assert call_kwargs["Bucket"] == "test-reports-bucket"
    assert call_kwargs["Key"] == "reports/2026-W39.csv"


@patch.dict(os.environ, {"REPORTS_BUCKET_NAME": "test-reports-bucket"})
@patch("boto3.client")
def test_handler_sqs_invocation_schedule_null_week(mock_boto_client):
    mock_s3 = MagicMock()
    mock_boto_client.return_value = mock_s3

    sqs_event = {
        "Records": [
            {
                "messageId": "msg-67890",
                "body": json.dumps({"week": None, "source": "schedule"}),
                "eventSource": "aws:sqs",
            }
        ]
    }
    result = handler(sqs_event)

    assert result["statusCode"] == 200
    assert re.match(r"^\d{4}-W\d{2}$", result["week"])
    assert result["key"] == f"reports/{result['week']}.csv"

"""Tests for S3-triggered report mailer Lambda handler."""

import os
from io import BytesIO
from unittest.mock import MagicMock, patch

from app.reports.mailer_handler import handler


@patch.dict(
    os.environ,
    {
        "SENDER_EMAIL": "test-sender@example.com",
        "RECIPIENT_EMAIL": "test-recipient@example.com",
    },
)
@patch("boto3.client")
def test_mailer_handler_success(mock_boto_client):
    mock_s3 = MagicMock()
    mock_ses = MagicMock()

    def client_factory(service_name):
        if service_name == "s3":
            return mock_s3
        if service_name == "sesv2":
            return mock_ses
        return MagicMock()

    mock_boto_client.side_effect = client_factory

    sample_csv = b"Title,Duration\nTest,1.0\n"
    mock_s3.get_object.return_value = {"Body": BytesIO(sample_csv)}
    mock_ses.send_email.return_value = {"MessageId": "ses-msg-12345"}

    s3_event = {
        "Records": [
            {
                "s3": {
                    "bucket": {"name": "test-reports-bucket"},
                    "object": {"key": "reports/2026-W38.csv"},
                }
            }
        ]
    }

    result = handler(s3_event)

    assert result["statusCode"] == 200
    assert result["bucket"] == "test-reports-bucket"
    assert result["key"] == "reports/2026-W38.csv"
    assert result["bytes_count"] == len(sample_csv)

    mock_s3.get_object.assert_called_once_with(
        Bucket="test-reports-bucket", Key="reports/2026-W38.csv"
    )
    mock_ses.send_email.assert_called_once()
    ses_kwargs = mock_ses.send_email.call_args.kwargs
    assert ses_kwargs["FromEmailAddress"] == "test-sender@example.com"
    assert ses_kwargs["Destination"]["ToAddresses"] == ["test-recipient@example.com"]
    raw_bytes = ses_kwargs["Content"]["Raw"]["Data"]
    assert b"Content-Type: text/csv" in raw_bytes
    assert b"Weekly Meeting Report: 2026-W38.csv" in raw_bytes


@patch.dict(
    os.environ,
    {
        "SENDER_EMAIL": "unverified@example.com",
        "RECIPIENT_EMAIL": "test-recipient@example.com",
        "VERIFIED_SENDER_EMAIL": "test-recipient@example.com",
    },
)
@patch("boto3.client")
def test_mailer_handler_fallback_on_unverified_sender(mock_boto_client):
    mock_s3 = MagicMock()
    mock_ses = MagicMock()

    def client_factory(service_name):
        if service_name == "s3":
            return mock_s3
        if service_name == "sesv2":
            return mock_ses
        return MagicMock()

    mock_boto_client.side_effect = client_factory

    sample_csv = b"Title,Duration\nTest,2.0\n"
    mock_s3.get_object.return_value = {"Body": BytesIO(sample_csv)}

    # First attempt fails with unverified identity, second attempt succeeds
    mock_ses.send_email.side_effect = [
        Exception("Email address is not verified: unverified@example.com"),
        {"MessageId": "ses-msg-fallback-67890"},
    ]

    s3_event = {
        "Records": [
            {
                "s3": {
                    "bucket": {"name": "test-reports-bucket"},
                    "object": {"key": "reports/2026-W38.csv"},
                }
            }
        ]
    }

    result = handler(s3_event)

    assert result["statusCode"] == 200
    assert mock_ses.send_email.call_count == 2
    # Verify second call used verified sender
    fallback_kwargs = mock_ses.send_email.call_args_list[1].kwargs
    assert fallback_kwargs["FromEmailAddress"] == "test-recipient@example.com"


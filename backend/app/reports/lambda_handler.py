"""AWS Lambda handler for generating and uploading weekly meeting reports."""

import json
import logging
import os
import re
import sys
from datetime import UTC, datetime, timedelta
from typing import Any

import boto3

from app.db import Base, engine
from app.reports.weekly import build_weekly_report


class ContextFormatter(logging.Formatter):
    """Custom logging formatter supporting extra fields in log output."""

    def format(self, record: logging.LogRecord) -> str:
        base_message = super().format(record)
        standard_keys = {
            "name",
            "msg",
            "args",
            "levelname",
            "levelno",
            "pathname",
            "filename",
            "module",
            "exc_info",
            "exc_text",
            "stack_info",
            "lineno",
            "funcName",
            "created",
            "msecs",
            "relativeCreated",
            "thread",
            "threadName",
            "processName",
            "process",
            "message",
            "asctime",
        }
        extra_fields = {k: v for k, v in record.__dict__.items() if k not in standard_keys}
        if extra_fields:
            try:
                return f"{base_message} | {json.dumps(extra_fields, default=str)}"
            except Exception:
                return f"{base_message} | {extra_fields}"
        return base_message


# Configure logger
log = logging.getLogger("report-builder")
if not log.handlers:
    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setFormatter(
        ContextFormatter("%(asctime)s [%(levelname)s] %(name)s: %(message)s")
    )
    log.addHandler(stream_handler)
log.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())


def detect_trigger(event: dict[str, Any] | Any) -> str:
    """Identify the trigger source of the Lambda invocation."""
    if not isinstance(event, dict):
        return "manual"
    if "Records" in event and isinstance(event["Records"], list) and len(event["Records"]) > 0:
        first_rec = event["Records"][0]
        if isinstance(first_rec, dict):
            event_source = first_rec.get("eventSource") or first_rec.get("EventSource")
            if event_source in ("aws:sqs", "sqs"):
                return "sqs"
            if event_source:
                return str(event_source)
        return "sqs"
    if "source" in event and event["source"]:
        return str(event["source"])
    if "detail-type" in event and event["detail-type"]:
        return str(event["detail-type"])
    if "requestContext" in event:
        return "api"
    return "manual"


def get_previous_iso_week() -> str:
    """Calculate the ISO week string for the previous week (e.g. '2026-W40')."""
    now_utc = datetime.now(UTC).date()
    prev_week_date = now_utc - timedelta(days=7)
    iso_year, iso_week, _ = prev_week_date.isocalendar()
    return f"{iso_year}-W{iso_week:02d}"


def handler(event: dict[str, Any] | None, context: Any = None) -> dict[str, Any]:
    """Lambda function handler for weekly meeting report generation and S3 upload."""
    if event is None:
        event = {}

    trigger = detect_trigger(event)

    # Support both Direct Invocation and SQS Event formats
    if "Records" in event and isinstance(event["Records"], list) and len(event["Records"]) > 0:
        first_rec = event["Records"][0]
        body_raw = first_rec.get("body", "{}") if isinstance(first_rec, dict) else "{}"
        if isinstance(body_raw, str):
            try:
                body_params = json.loads(body_raw)
            except Exception as err:
                log.warning(f"Failed to parse SQS message body as JSON: {err}")
                body_params = {}
                m_week = re.search(r'week["\':\s]+([0-9]{4}-[Ww][0-9]{1,2})', body_raw)
                if m_week:
                    body_params["week"] = m_week.group(1)
        elif isinstance(body_raw, dict):
            body_params = body_raw
        else:
            body_params = {}
        week = body_params.get("week")
    else:
        week = event.get("week")

    if not week:
        week = get_previous_iso_week()
    else:
        week = str(week).strip()

    # Required log statement at execution start
    log.info(
        "report-builder triggered",
        extra={"trigger": trigger, "week": week},
    )

    # Ensure tables exist (e.g. on fresh or SQLite databases)
    try:
        Base.metadata.create_all(bind=engine)
    except Exception as exc:
        log.warning(f"Database table verification skipped/warning: {exc}")

    # Build weekly report CSV
    try:
        csv_bytes = build_weekly_report(week)
    except ValueError as val_err:
        log.warning(
            f"Invalid week requested '{week}': {val_err}. Generating fallback error report.",
            extra={"invalid_week": week, "error": str(val_err)},
        )
        csv_bytes = (
            f"Status,RequestedWeek,Message\n"
            f"ERROR,{week},Week is not a valid ISO week (weeks must be 01-53)\n"
        ).encode("utf-8")

    bucket_name = os.getenv("REPORTS_BUCKET_NAME")
    if not bucket_name:
        raise ValueError("Environment variable 'REPORTS_BUCKET_NAME' is required but not set")

    s3_key = f"reports/{week}.csv"

    # Upload CSV to S3
    s3_client = boto3.client("s3")
    s3_client.put_object(
        Bucket=bucket_name,
        Key=s3_key,
        Body=csv_bytes,
        ContentType="text/csv",
    )

    log.info(
        "report-builder completed",
        extra={"bucket": bucket_name, "key": s3_key, "size_bytes": len(csv_bytes)},
    )

    return {
        "statusCode": 200,
        "bucket": bucket_name,
        "key": s3_key,
        "week": week,
        "size_bytes": len(csv_bytes),
    }

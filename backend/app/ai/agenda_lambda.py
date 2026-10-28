"""AWS Lambda Function URL handler for parsing meeting agendas via Amazon Bedrock."""

import base64
import json
import logging
import os
import sys
import time
from datetime import UTC, date, datetime
from functools import lru_cache
from typing import Any

import jwt
from jwt import PyJWKClient

from app.ai.agenda import DEFAULT_MODEL, PROMPT_VERSION, AgendaParseError, parse_agenda

MAX_TEXT_LENGTH = 10_000

# Model pricing per 1,000 tokens (input_usd, output_usd)
MODEL_PRICING_PER_1K: dict[str, tuple[float, float]] = {
    "sonnet": (0.003, 0.015),
    "haiku": (0.001, 0.005),
    "opus": (0.015, 0.075),
}

log = logging.getLogger("agenda-parser")
if not log.handlers:
    stream_handler = logging.StreamHandler(sys.stdout)
    stream_handler.setFormatter(logging.Formatter("%(message)s"))
    log.addHandler(stream_handler)
log.setLevel(os.getenv("LOG_LEVEL", "INFO").upper())


def cost_usd(model: str, usage: dict[str, int]) -> float:
    """Calculate the estimated Bedrock inference cost in USD based on token usage."""
    model_lower = model.lower()
    in_rate, out_rate = MODEL_PRICING_PER_1K["sonnet"]
    for family, rates in MODEL_PRICING_PER_1K.items():
        if family in model_lower:
            in_rate, out_rate = rates
            break

    input_tokens = usage.get("input_tokens", 0)
    output_tokens = usage.get("output_tokens", 0)
    total = (input_tokens * in_rate + output_tokens * out_rate) / 1000.0
    return round(total, 6)


@lru_cache(maxsize=4)
def _get_jwk_client(jwks_url: str) -> PyJWKClient:
    return PyJWKClient(jwks_url)


def verify_cognito_token(auth_header: str | None) -> dict[str, Any]:
    """Verify a Cognito Bearer JWT using the User Pool's JWKS endpoint.

    Raises ValueError if the header is missing or the token is invalid.
    """
    if not auth_header or not isinstance(auth_header, str):
        raise ValueError("Missing Authorization header")

    parts = auth_header.strip().split(" ", 1)
    if len(parts) != 2 or parts[0].lower() != "bearer" or not parts[1].strip():
        raise ValueError("Authorization header must be 'Bearer <token>'")

    token = parts[1].strip()

    region = (
        os.getenv("COGNITO_REGION")
        or os.getenv("AWS_REGION")
        or os.getenv("AWS_DEFAULT_REGION")
        or "us-east-1"
    )
    user_pool_id = os.getenv("COGNITO_USER_POOL_ID") or os.getenv("USER_POOL_ID") or ""
    client_id = (
        os.getenv("COGNITO_CLIENT_ID")
        or os.getenv("USER_POOL_CLIENT_ID")
        or os.getenv("APP_CLIENT_ID")
        or ""
    )

    if not user_pool_id:
        raise ValueError("COGNITO_USER_POOL_ID is not configured")

    issuer = f"https://cognito-idp.{region}.amazonaws.com/{user_pool_id}"
    jwks_url = f"{issuer}/.well-known/jwks.json"

    jwk_client = _get_jwk_client(jwks_url)
    signing_key = jwk_client.get_signing_key_from_jwt(token)

    claims: dict[str, Any] = jwt.decode(
        token,
        signing_key.key,
        algorithms=["RS256"],
        issuer=issuer,
        options={"verify_aud": False},
    )

    if client_id:
        token_client = claims.get("client_id") or claims.get("aud")
        if token_client != client_id:
            raise ValueError("Token client_id/aud mismatch")

    token_use = claims.get("token_use")
    if token_use and token_use not in ("access", "id"):
        raise ValueError(f"Unsupported token_use: {token_use}")

    return claims


def _json_response(status_code: int, payload: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status_code,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(payload, ensure_ascii=False),
    }


def _extract_auth_header(event: dict[str, Any]) -> str | None:
    headers = event.get("headers")
    if not isinstance(headers, dict):
        return None
    for k, v in headers.items():
        if isinstance(k, str) and k.lower() == "authorization":
            return str(v)
    return None


def _parse_body(event: dict[str, Any]) -> dict[str, Any]:
    raw_body = event.get("body")
    if raw_body is None:
        return {}
    if isinstance(raw_body, dict):
        return raw_body
    if event.get("isBase64Encoded") and isinstance(raw_body, str):
        raw_body = base64.b64decode(raw_body).decode("utf-8")
    if isinstance(raw_body, str):
        parsed = json.loads(raw_body)
        if not isinstance(parsed, dict):
            raise ValueError("JSON body must be an object")
        return parsed
    raise ValueError("Unsupported request body format")


def handler(event: dict[str, Any] | None, context: Any = None) -> dict[str, Any]:
    """Lambda Function URL entrypoint for agenda parsing."""
    if event is None or not isinstance(event, dict):
        event = {}

    # 1. Verify Cognito JWT token
    auth_header = _extract_auth_header(event)
    try:
        claims = verify_cognito_token(auth_header)
    except Exception as exc:
        return _json_response(401, {"error": f"Unauthorized: {exc}"})

    user_id = str(claims.get("sub") or claims.get("email") or claims.get("username") or "unknown")

    # 2. Parse and validate JSON body
    try:
        body = _parse_body(event)
    except Exception as exc:
        return _json_response(400, {"error": f"Invalid request body: {exc}"})

    text = body.get("text")
    if not isinstance(text, str) or not text.strip():
        return _json_response(
            400, {"error": "Field 'text' is required and must be a non-empty string"}
        )

    if len(text) > MAX_TEXT_LENGTH:
        return _json_response(
            413,
            {"error": f"Input text exceeds maximum length of {MAX_TEXT_LENGTH} characters"},
        )

    today_raw = body.get("today")
    if today_raw:
        try:
            today = date.fromisoformat(str(today_raw))
        except ValueError:
            return _json_response(
                400, {"error": "Field 'today' must be an ISO date string (YYYY-MM-DD)"}
            )
    else:
        today = datetime.now(UTC).date()

    tz = str(body.get("tz") or "UTC")
    model = os.getenv("PARSER_MODEL", DEFAULT_MODEL)

    # 3. Call parse_agenda and measure latency
    t0 = time.perf_counter()
    try:
        agenda, usage = parse_agenda(text=text, today=today, tz=tz, model_id=model)
    except AgendaParseError as err:
        return _json_response(422, {"error": str(err)})
    latency_ms = round((time.perf_counter() - t0) * 1000)

    # 4. Calculate cost and emit structured JSON log
    call_cost = cost_usd(model, usage)
    log_record = {
        "user": user_id,
        "model": model,
        "prompt_version": PROMPT_VERSION,
        "input_tokens": usage["input_tokens"],
        "output_tokens": usage["output_tokens"],
        "latency_ms": latency_ms,
        "cost_usd": call_cost,
    }
    log.info(json.dumps(log_record))

    # 5. Return 200 JSON response
    return _json_response(
        200,
        {
            "agenda": agenda.model_dump(mode="json"),
            "model": model,
            "prompt_version": PROMPT_VERSION,
        },
    )

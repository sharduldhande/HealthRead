"""HealthRead reading service.

An AWS Lambda function (behind a Function URL) that takes one JPEG of a blood
pressure monitor or bathroom scale and returns the numbers as JSON, read by Claude.

No Anthropic API key exists for this service. It signs in with Workload Identity
Federation: the function's AWS role asks AWS STS for a short-lived token (audience
https://api.anthropic.com), and the Anthropic SDK trades it for a short-lived access
token under a federation rule in the Claude Console. The iOS app holds no key either.
Photos are not stored or logged: only token counts and timing are logged.

Only genuine HealthRead installs can use it (Apple App Attest), and use is capped per
device and per day (DynamoDB counters), so the Claude bill can't be run up by strangers.

Endpoints (all POST):
  /challenge  -> {"challenge": "<base64>"}              one-time value for /attest
  /attest     {"key_id", "attestation", "challenge"}     registers an App Attest key
  /read       {"image_jpeg_base64": "<base64 JPEG>"}     headers X-AppAttest-Key-Id and
              X-AppAttest-Assertion (assertion over SHA256 of the exact request body)
     200 {"device_type": "blood_pressure" | "weight_scale" | "none",
          "systolic": int|null, "diastolic": int|null, "pulse": int|null,
          "weight_value": number|null, "weight_unit": "kg"|"lbs"|null}
     401 {"error": "attest_required"}   the app should attest (again) and retry once
     429 {"error": "limit", "limit": "device" | "global"}
"""

import base64
import binascii
import hmac
import json
import os
import time

import anthropic
import boto3
from anthropic.lib.credentials import WorkloadIdentityCredentials

import analytics
import store
from appattest import AttestationError, verify_assertion, verify_attestation

MODEL = os.environ.get("MODEL", "claude-opus-5-5")
EFFORT = os.environ.get("EFFORT", "low")
ANTHROPIC_AUDIENCE = "https://api.anthropic.com"
MAX_IMAGE_BYTES = 1_500_000  # the app sends about 100-400 KB
APP_ID = os.environ.get("APP_ID", "")  # "<TEAM ID>.<bundle ID>"
ALLOW_DEVELOPMENT_KEYS = os.environ.get("ALLOW_DEVELOPMENT_KEYS", "true") == "true"
PER_DEVICE_DAILY_LIMIT = int(os.environ.get("PER_DEVICE_DAILY_LIMIT", "20"))
GLOBAL_DAILY_LIMIT = int(os.environ.get("GLOBAL_DAILY_LIMIT", "300"))
# For testing from a Mac or the Simulator, where App Attest doesn't exist. Empty = disabled.
DEV_BYPASS_TOKEN = os.environ.get("DEV_BYPASS_TOKEN", "")
# Opus 5.5 list prices, for the cost estimate sent to analytics.
USD_PER_INPUT_TOKEN = 4 / 1_000_000
USD_PER_OUTPUT_TOKEN = 20 / 1_000_000

INSTRUCTIONS = """You read the display of a home health device in a photo and report the numbers exactly as shown.

If the photo shows a BLOOD PRESSURE MONITOR:
- systolic is the value labeled SYS (usually the top, largest row)
- diastolic is the value labeled DIA (usually the middle row)
- pulse is the value labeled PUL, PULSE or with a heart symbol (usually the bottom row), if shown
- Read each value from its label. Do not reorder values or guess missing digits.

If the photo shows a BATHROOM WEIGHT SCALE:
- weight_value is the number on the display, including any decimal point
- weight_unit is "kg" or "lbs" from the unit shown on the display; if no unit is visible, use "lbs"

If the photo does not clearly show either device's display, report device_type "none".
Ignore clocks, dates, memory numbers and printed text that is not part of the reading.
Set every field that does not apply to null."""

READING_SCHEMA = {
    "type": "object",
    "properties": {
        "device_type": {"type": "string", "enum": ["blood_pressure", "weight_scale", "none"]},
        "systolic": {"type": ["integer", "null"]},
        "diastolic": {"type": ["integer", "null"]},
        "pulse": {"type": ["integer", "null"]},
        "weight_value": {"type": ["number", "null"]},
        "weight_unit": {"anyOf": [{"type": "string", "enum": ["kg", "lbs"]}, {"type": "null"}]},
    },
    "required": ["device_type", "systolic", "diastolic", "pulse", "weight_value", "weight_unit"],
    "additionalProperties": False,
}

_client = None
_sts = None


def _aws_identity_token():
    """A fresh AWS-signed JWT for this function's role (valid 5 minutes).

    GetWebIdentityToken isn't served by the STS global endpoint, so use the regional one.
    """
    global _sts
    if _sts is None:
        region = os.environ["AWS_REGION"]
        _sts = boto3.client("sts", region_name=region, endpoint_url=f"https://sts.{region}.amazonaws.com")
    try:
        token = _sts.get_web_identity_token(
            Audience=[ANTHROPIC_AUDIENCE], SigningAlgorithm="RS256", DurationSeconds=300
        )["WebIdentityToken"]
    except Exception as e:  # the SDK reports provider failures as connection errors
        code = getattr(e, "response", {}).get("Error", {}).get("Code", type(e).__name__)
        print(json.dumps({"event": "aws_identity_token_error", "code": code}))
        raise
    _log_token_identity(token)
    return token


_logged_identity = False


def _log_token_identity(token):
    """Logs the token's issuer, subject and audience once per container (never the token).

    These are what the federation rule in the Claude Console must match.
    """
    global _logged_identity
    if _logged_identity:
        return
    _logged_identity = True
    try:
        payload = token.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
        print(json.dumps({"event": "aws_identity", "iss": claims.get("iss"),
                          "sub": claims.get("sub"), "aud": claims.get("aud")}))
    except (IndexError, ValueError):
        pass


def _anthropic_client():
    """Created once per Lambda container. The SDK caches the Anthropic access token and
    calls `_aws_identity_token` again when it needs a new one."""
    global _client
    if _client is None:
        credentials = WorkloadIdentityCredentials(
            identity_token_provider=_aws_identity_token,
            federation_rule_id=os.environ["ANTHROPIC_FEDERATION_RULE_ID"],
            organization_id=os.environ["ANTHROPIC_ORGANIZATION_ID"],
            service_account_id=os.environ.get("ANTHROPIC_SERVICE_ACCOUNT_ID") or None,
            workspace_id=os.environ.get("ANTHROPIC_WORKSPACE_ID") or None,
        )
        _client = anthropic.Anthropic(credentials=credentials, max_retries=1, timeout=20.0)
    return _client


def _reply(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json", "Cache-Control": "no-store"},
        "body": json.dumps(body),
    }


def _decode_image(body_text):
    """Returns (jpeg_bytes, None) or (None, error_response)."""
    try:
        image_b64 = json.loads(body_text)["image_jpeg_base64"]
        jpeg = base64.b64decode(image_b64, validate=True)
    except (ValueError, KeyError, TypeError, binascii.Error):
        return None, _reply(400, {"error": "Send JSON with an image_jpeg_base64 field."})
    if len(jpeg) > MAX_IMAGE_BYTES:
        return None, _reply(413, {"error": "Image too large."})
    if not jpeg.startswith(b"\xff\xd8"):
        return None, _reply(415, {"error": "Image must be a JPEG."})
    return jpeg, None


def _b64(value):
    try:
        return base64.b64decode(value or "", validate=True)
    except (binascii.Error, ValueError, TypeError):
        return b""


def handler(event, context):
    http = event.get("requestContext", {}).get("http", {})
    if http.get("method") != "POST":
        return _reply(405, {"error": "Use POST."})
    raw = event.get("body") or ""
    body = base64.b64decode(raw) if event.get("isBase64Encoded") else raw.encode("utf-8")
    headers = {k.lower(): v for k, v in (event.get("headers") or {}).items()}
    install_id = headers.get("x-healthread-install-id", "")[:64]
    path = http.get("path", "/").rstrip("/") or "/"

    if path == "/challenge":
        return _reply(200, {"challenge": base64.b64encode(store.new_challenge()).decode()})
    if path == "/attest":
        return _attest(body, install_id)
    if path in ("/", "/read"):
        return _read(body, headers, install_id)
    return _reply(404, {"error": "Not found."})


def _attest(body, install_id):
    try:
        request = json.loads(body)
        key_id_b64 = request["key_id"]
        key_id, attestation, challenge = _b64(key_id_b64), _b64(request["attestation"]), _b64(request["challenge"])
    except (ValueError, KeyError, TypeError):
        return _reply(400, {"error": "Send key_id, attestation and challenge."})
    if not (key_id and attestation and challenge) or not store.consume_challenge(challenge):
        analytics.capture("reading_service_attest", install_id, {"outcome": "bad_challenge"})
        return _reply(401, {"error": "attest_required"})
    try:
        key = verify_attestation(attestation, key_id, challenge, APP_ID, ALLOW_DEVELOPMENT_KEYS)
    except AttestationError as e:
        print(json.dumps({"event": "attest_rejected", "reason": str(e)}))
        analytics.capture("reading_service_attest", install_id, {"outcome": "rejected", "reason": str(e)})
        return _reply(401, {"error": "attest_required"})
    store.save_key(key_id_b64, key.public_key_der, key.environment)
    analytics.capture("reading_service_attest", install_id, {"outcome": "ok", "environment": key.environment})
    return _reply(200, {"ok": True})


def _authorize(body, headers):
    """Returns (device_id, None) for a genuine app request, else (None, reason)."""
    if DEV_BYPASS_TOKEN and hmac.compare_digest(headers.get("x-healthread-dev-token", ""), DEV_BYPASS_TOKEN):
        return "dev-bypass", None
    key_id_b64 = headers.get("x-appattest-key-id", "")
    assertion = _b64(headers.get("x-appattest-assertion"))
    if not key_id_b64 or not assertion:
        return None, "missing_assertion"
    key = store.get_key(key_id_b64)
    if key is None:
        return None, "unknown_key"
    try:
        counter = verify_assertion(assertion, body, key["public_key"], APP_ID, key["counter"])
    except AttestationError as e:
        return None, f"bad_assertion: {e}"
    if not store.advance_counter(key_id_b64, counter):
        return None, "replayed"
    return key_id_b64, None


def _read(body, headers, install_id):
    started = time.monotonic()

    device_id, reason = _authorize(body, headers)

    def report(outcome, status, payload, **extra):
        analytics.capture("reading_service_request", install_id, {
            "outcome": outcome, "status": status, "model": MODEL,
            "ms": int((time.monotonic() - started) * 1000),
            # Test-token requests are excluded from dashboards as test traffic.
            "test_request": device_id == "dev-bypass", **extra,
        })
        return _reply(status, payload)

    if device_id is None:
        print(json.dumps({"event": "read_rejected", "reason": reason}))
        return report("unauthorized", 401, {"error": "attest_required"}, reason=reason.split(":")[0])

    jpeg, error = _decode_image(body.decode("utf-8", errors="replace"))
    if error:
        return report("bad_request", error["statusCode"], json.loads(error["body"]))

    limit_hit = store.take_reading_slot(device_id, PER_DEVICE_DAILY_LIMIT, GLOBAL_DAILY_LIMIT)
    if limit_hit:
        print(json.dumps({"event": "limit_hit", "limit": limit_hit}))
        return report("rate_limited", 429, {"error": "limit", "limit": limit_hit}, limit=limit_hit)

    try:
        response = _anthropic_client().beta.messages.create(
            model=MODEL,
            max_tokens=2000,
            system=INSTRUCTIONS,
            messages=[{
                "role": "user",
                "content": [
                    {
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": base64.standard_b64encode(jpeg).decode("ascii"),
                        },
                    },
                    {"type": "text", "text": "Read the display in this photo."},
                ],
            }],
            output_config={
                "effort": EFFORT,
                "format": {"type": "json_schema", "schema": READING_SCHEMA},
            },
            # If a safety classifier declines, the API retries on a fallback model in the same call.
            betas=["server-side-fallback-2026-07-01"],
            fallbacks="default",
        )
    except anthropic.RateLimitError:
        return report("claude_rate_limited", 429, {"error": "Busy. Try again shortly."})
    except anthropic.APIStatusError as e:
        print(json.dumps({"event": "anthropic_error", "status": e.status_code, "message": str(e.message)[:500]}))
        return report("claude_error", 502, {"error": "Reader unavailable."}, claude_status=e.status_code)
    except anthropic.APIConnectionError:
        print(json.dumps({"event": "anthropic_connection_error"}))
        return report("claude_connection_error", 502, {"error": "Reader unavailable."})
    except anthropic.AnthropicError as e:
        # e.g. the federation rule doesn't match this function's identity
        print(json.dumps({"event": "anthropic_auth_error", "type": type(e).__name__}))
        return report("claude_auth_error", 502, {"error": "Reader unavailable."})

    usage = response.usage
    tokens = {
        "input_tokens": usage.input_tokens,
        "output_tokens": usage.output_tokens,
        "cost_usd": round(usage.input_tokens * USD_PER_INPUT_TOKEN + usage.output_tokens * USD_PER_OUTPUT_TOKEN, 5),
        "claude_ms": int((time.monotonic() - started) * 1000),
    }
    print(json.dumps({"event": "read", "model": response.model, "stop_reason": response.stop_reason, **tokens}))

    if response.stop_reason != "end_turn":
        # refusal (whole fallback chain declined) or max_tokens: report "no reading"
        return report("no_reading", 422, {"error": "Couldn't read this photo."},
                      stop_reason=response.stop_reason, **tokens)

    text = next((b.text for b in response.content if b.type == "text"), None)
    try:
        reading = json.loads(text)
    except (TypeError, ValueError):
        return report("bad_answer", 502, {"error": "Reader returned an unexpected answer."}, **tokens)
    # Only the kind of device goes to analytics, never the numbers.
    return report("ok", 200, reading, device_type=reading.get("device_type"), **tokens)

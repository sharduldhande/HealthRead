"""HealthRead reading service.

An AWS Lambda function (behind a Function URL) that takes one JPEG of a blood
pressure monitor or bathroom scale and returns the numbers as JSON, read by Claude.

No Anthropic API key exists for this service. It signs in with Workload Identity
Federation: the function's AWS role asks AWS STS for a short-lived token (audience
https://api.anthropic.com), and the Anthropic SDK trades it for a short-lived access
token under a federation rule in the Claude Console. The iOS app holds no key either.
Photos are not stored or logged: only token counts and timing are logged.

Request:  POST {"image_jpeg_base64": "<base64 JPEG>"}
Response: 200 {"device_type": "blood_pressure" | "weight_scale" | "none",
               "systolic": int|null, "diastolic": int|null, "pulse": int|null,
               "weight_value": number|null, "weight_unit": "kg"|"lbs"|null}
          4xx/5xx {"error": "<short reason>"}
"""

import base64
import binascii
import json
import os
import time

import anthropic
import boto3
from anthropic.lib.credentials import WorkloadIdentityCredentials

MODEL = os.environ.get("MODEL", "claude-opus-5-5")
EFFORT = os.environ.get("EFFORT", "low")
ANTHROPIC_AUDIENCE = "https://api.anthropic.com"
MAX_IMAGE_BYTES = 1_500_000  # the app sends about 100-400 KB

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


def _decode_image(event):
    """Returns (jpeg_bytes, None) or (None, error_response)."""
    if event.get("requestContext", {}).get("http", {}).get("method") != "POST":
        return None, _reply(405, {"error": "Use POST."})
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8", errors="replace")
    try:
        image_b64 = json.loads(raw)["image_jpeg_base64"]
        jpeg = base64.b64decode(image_b64, validate=True)
    except (ValueError, KeyError, TypeError, binascii.Error):
        return None, _reply(400, {"error": "Send JSON with an image_jpeg_base64 field."})
    if len(jpeg) > MAX_IMAGE_BYTES:
        return None, _reply(413, {"error": "Image too large."})
    if not jpeg.startswith(b"\xff\xd8"):
        return None, _reply(415, {"error": "Image must be a JPEG."})
    return jpeg, None


def handler(event, context):
    jpeg, error = _decode_image(event)
    if error:
        return error

    started = time.monotonic()
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
        return _reply(429, {"error": "Busy. Try again shortly."})
    except anthropic.APIStatusError as e:
        print(json.dumps({"event": "anthropic_error", "status": e.status_code, "message": str(e.message)[:500]}))
        return _reply(502, {"error": "Reader unavailable."})
    except anthropic.APIConnectionError:
        print(json.dumps({"event": "anthropic_connection_error"}))
        return _reply(502, {"error": "Reader unavailable."})
    except anthropic.AnthropicError as e:
        # e.g. the federation rule doesn't match this function's identity yet
        print(json.dumps({"event": "anthropic_auth_error", "type": type(e).__name__}))
        return _reply(502, {"error": "Reader unavailable."})

    usage = response.usage
    print(json.dumps({
        "event": "read",
        "model": response.model,
        "stop_reason": response.stop_reason,
        "input_tokens": usage.input_tokens,
        "output_tokens": usage.output_tokens,
        "ms": int((time.monotonic() - started) * 1000),
    }))

    if response.stop_reason != "end_turn":
        # refusal (whole fallback chain declined) or max_tokens: report "no reading"
        return _reply(422, {"error": "Couldn't read this photo."})

    text = next((b.text for b in response.content if b.type == "text"), None)
    try:
        reading = json.loads(text)
    except (TypeError, ValueError):
        return _reply(502, {"error": "Reader returned an unexpected answer."})
    return _reply(200, reading)

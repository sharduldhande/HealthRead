"""HealthRead reading service.

An AWS Lambda function (behind a Function URL) that takes one JPEG of a blood
pressure monitor or bathroom scale and returns the numbers as JSON, read by Claude.

The Anthropic API key lives in AWS Secrets Manager and never leaves AWS; the iOS app
holds no key. Photos are not stored or logged: only token counts and timing are logged.

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

MODEL = os.environ.get("MODEL", "claude-opus-5-5")
EFFORT = os.environ.get("EFFORT", "low")
SECRET_ID = os.environ["ANTHROPIC_KEY_SECRET_ID"]
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
        "weight_unit": {"type": ["string", "null"], "enum": ["kg", "lbs", None]},
    },
    "required": ["device_type", "systolic", "diastolic", "pulse", "weight_value", "weight_unit"],
    "additionalProperties": False,
}

_client = None


def _anthropic_client():
    """Created once per Lambda container; the key is read from Secrets Manager, never logged."""
    global _client
    if _client is None:
        secret = boto3.client("secretsmanager").get_secret_value(SecretId=SECRET_ID)["SecretString"]
        _client = anthropic.Anthropic(api_key=secret.strip(), max_retries=1, timeout=20.0)
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
        print(json.dumps({"event": "anthropic_error", "status": e.status_code}))
        return _reply(502, {"error": "Reader unavailable."})
    except anthropic.APIConnectionError:
        print(json.dumps({"event": "anthropic_connection_error"}))
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

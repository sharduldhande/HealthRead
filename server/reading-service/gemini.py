"""Reads a display photo with Google's Gemini Decision 1 (Decisions API).

Decision models don't write text: they answer typed questions with calibrated
probabilities. There is no number type, so each value is a multiple-choice question
whose options are the plausible numbers themselves ("60" ... "259"), plus "unreadable".
On 40 labeled home blood pressure photos this read 38/40 fully right with 1 wrong value
(see the README), better than every Claude model tested, in about 0.9 s.

A choice question allows at most 255 options, so a weight is asked in parts: the whole
number (2-254, or a second question for 255-499), the tenths digit, and the unit.

The API key lives in AWS Secrets Manager and is read once per container.
"""

import json
import os
import time
import urllib.error
import urllib.request

import boto3

MODEL = "gemini-decision-1"
URL = "https://generativelanguage.googleapis.com/v1beta/decisions"
USD_PER_INPUT_TOKEN = 0.10 / 1_000_000  # no output tokens
UNSURE_BELOW = 0.8  # values below this confidence are listed as "unclear" (analytics only)

HIDDEN = "Not readable: glare, a reflection, blur or the photo edge hides a digit, or the value isn't shown."


class RateLimited(Exception):
    """Gemini answered 429. The caller falls back to Claude."""


class ReaderError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


def _numbers(lo, hi):
    return {str(v): str(v) for v in range(lo, hi + 1)}


def _choice(instructions, options):
    return {"type": "choice", "instructions": instructions, "criteria": {**options, "unreadable": HIDDEN}}


QUESTIONS = {
    "device_type": {"type": "choice", "instructions": "Which home health device's display is in the photo?",
                    "criteria": {"blood_pressure": "A blood pressure monitor's display",
                                 "weight_scale": "A bathroom weight scale's display",
                                 "none": "Neither device's display is clearly visible"}},
    "systolic": _choice("Read the blood pressure value labeled SYS (usually the top, largest row). "
                        "Never guess a hidden digit.", _numbers(60, 259)),
    "diastolic": _choice("Read the blood pressure value labeled DIA (usually the middle row). "
                         "Never guess a hidden digit.", _numbers(30, 159)),
    "pulse": _choice("Read the pulse labeled PUL, PULSE or with a heart symbol (usually the bottom row). "
                     "Never guess a hidden digit.", _numbers(30, 199)),
    "weight_whole": _choice("On a bathroom scale's display, read the whole-number part of the weight "
                            "(the digits before any decimal point). Never guess a hidden digit.",
                            {**_numbers(2, 254), "over_254": "The whole number is 255 or more"}),
    "weight_whole_high": _choice("On a bathroom scale's display, if the whole-number part of the weight is "
                                 "255 or more, read it. Never guess a hidden digit.", _numbers(255, 499)),
    "weight_tenths": _choice("On a bathroom scale's display, read the digit right after the decimal point.",
                             {"none": "The weight has no decimal point", **_numbers(0, 9)}),
    "weight_unit": {"type": "choice", "instructions": "Which weight unit is printed on the scale's display?",
                    "criteria": {"kg": "kg", "lbs": "lb or lbs",
                                 "none": "No unit is shown on the display (never guess it)"}},
}

_api_key = None


def _key():
    global _api_key
    if _api_key is None:
        secret = boto3.client("secretsmanager").get_secret_value(SecretId=os.environ["GEMINI_SECRET_ID"])
        _api_key = secret["SecretString"].strip()
    return _api_key


def _int_choice(answer):
    choice = (answer or {}).get("choice")
    return int(choice) if isinstance(choice, str) and choice.isdigit() else None


def read(jpeg_b64):
    """Returns {"reading": <the service's reading JSON>, "input_tokens", "cost_usd", "ms"}."""
    body = json.dumps({
        "model": MODEL,
        "input": [{"type": "image", "data": jpeg_b64, "mime_type": "image/jpeg", "resolution": "high"}],
        "questions": QUESTIONS,
    }).encode()
    request = urllib.request.Request(URL, data=body, method="POST",
                                     headers={"Content-Type": "application/json", "x-goog-api-key": _key()})
    started = time.monotonic()
    try:
        with urllib.request.urlopen(request, timeout=10) as r:
            response = json.loads(r.read())
    except urllib.error.HTTPError as e:
        if e.code == 429:
            raise RateLimited() from e
        try:
            message = json.loads(e.read()).get("error", {}).get("message", "")
        except ValueError:
            message = ""
        raise ReaderError(e.code, message[:300]) from e
    except (urllib.error.URLError, TimeoutError) as e:
        raise ReaderError(0, type(e).__name__) from e
    ms = int((time.monotonic() - started) * 1000)

    answers = response.get("answers", {})
    confidence = {name: (answers.get(name) or {}).get("confidence") or 0 for name in QUESTIONS}
    device = (answers.get("device_type") or {}).get("choice")
    reading = {"device_type": device if device in ("blood_pressure", "weight_scale") else "none",
               "systolic": None, "diastolic": None, "pulse": None,
               "weight_value": None, "weight_unit": None, "unclear": []}

    if reading["device_type"] == "blood_pressure":
        for name in ("systolic", "diastolic", "pulse"):
            reading[name] = _int_choice(answers.get(name))
            if reading[name] is not None and confidence[name] < UNSURE_BELOW:
                reading["unclear"].append(name)
    elif reading["device_type"] == "weight_scale":
        whole_answer = answers.get("weight_whole") or {}
        if whole_answer.get("choice") == "over_254":
            whole, whole_conf = _int_choice(answers.get("weight_whole_high")), confidence["weight_whole_high"]
        else:
            whole, whole_conf = _int_choice(whole_answer), confidence["weight_whole"]
        tenths_choice = (answers.get("weight_tenths") or {}).get("choice")
        if whole is not None and tenths_choice != "unreadable":
            tenths = int(tenths_choice) if isinstance(tenths_choice, str) and tenths_choice.isdigit() else 0
            reading["weight_value"] = round(whole + tenths / 10, 1)
            if min(whole_conf, confidence["weight_tenths"]) < UNSURE_BELOW:
                reading["unclear"].append("weight_value")
        unit = (answers.get("weight_unit") or {}).get("choice")
        reading["weight_unit"] = unit if unit in ("kg", "lbs") else None

    input_tokens = (response.get("usage") or {}).get("total_input_tokens", 0)
    return {"reading": reading, "input_tokens": input_tokens,
            "cost_usd": round(input_tokens * USD_PER_INPUT_TOKEN, 6), "ms": ms}

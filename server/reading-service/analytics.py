"""Minimal PostHog capture over HTTPS (no SDK). Sends service health only: outcome,
timing, token counts. Never photos, readings or anything about a person's health.
Disabled when POSTHOG_API_KEY is empty."""

import json
import os
import urllib.request

POSTHOG_API_KEY = os.environ.get("POSTHOG_API_KEY", "")
POSTHOG_HOST = os.environ.get("POSTHOG_HOST", "https://eu.i.posthog.com").rstrip("/")


def capture(event: str, distinct_id: str, properties: dict):
    if not POSTHOG_API_KEY:
        return
    body = json.dumps({
        "api_key": POSTHOG_API_KEY,
        "event": event,
        "distinct_id": distinct_id or "reading-service",
        "properties": {**properties, "$process_person_profile": False, "source": "reading-service"},
    }).encode()
    request = urllib.request.Request(f"{POSTHOG_HOST}/i/v0/e/", data=body,
                                     headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(request, timeout=2).read()
    except Exception as e:  # analytics must never break a reading
        print(json.dumps({"event": "posthog_error", "type": type(e).__name__}))

"""DynamoDB state for the reading service: one-time challenges, attested device keys and
daily usage counters. One table, partition key "pk"; old items expire through the "ttl"
attribute so nothing accumulates."""

import os
import secrets
import time
from datetime import datetime, timezone

import boto3
from boto3.dynamodb.conditions import Attr
from botocore.exceptions import ClientError

_table = None

CHALLENGE_TTL_SECONDS = 300
COUNTER_TTL_SECONDS = 3 * 24 * 3600


def table():
    global _table
    if _table is None:
        _table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
    return _table


def _today():
    return datetime.now(timezone.utc).strftime("%Y-%m-%d")


# --- challenges -----------------------------------------------------------------------

def new_challenge() -> bytes:
    challenge = secrets.token_bytes(32)
    table().put_item(Item={
        "pk": f"chal#{challenge.hex()}",
        "ttl": int(time.time()) + CHALLENGE_TTL_SECONDS,
    })
    return challenge


def consume_challenge(challenge: bytes) -> bool:
    """True once for a challenge we issued in the last 5 minutes; deletes it either way."""
    try:
        old = table().delete_item(
            Key={"pk": f"chal#{challenge.hex()}"},
            ReturnValues="ALL_OLD",
        ).get("Attributes")
    except ClientError:
        return False
    return bool(old) and int(old.get("ttl", 0)) >= int(time.time())


# --- attested keys ----------------------------------------------------------------------

def save_key(key_id_b64: str, public_key_der: bytes, environment: str):
    table().put_item(Item={
        "pk": f"key#{key_id_b64}",
        "public_key": public_key_der,
        "environment": environment,
        "counter": 0,
        "created": int(time.time()),
    })


def get_key(key_id_b64: str):
    item = table().get_item(Key={"pk": f"key#{key_id_b64}"}).get("Item")
    if not item:
        return None
    return {"public_key": bytes(item["public_key"]), "counter": int(item["counter"]),
            "environment": item.get("environment", "production")}


def advance_counter(key_id_b64: str, new_counter: int) -> bool:
    """Stores the assertion counter only if it grew, so two racing requests can't both pass."""
    try:
        table().update_item(
            Key={"pk": f"key#{key_id_b64}"},
            UpdateExpression="SET #c = :n",
            ConditionExpression=Attr("counter").lt(new_counter),
            ExpressionAttributeNames={"#c": "counter"},
            ExpressionAttributeValues={":n": new_counter},
        )
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


# --- daily caps -------------------------------------------------------------------------

def _take(pk: str, limit: int) -> bool:
    """Atomically adds one to today's counter if it is below `limit`."""
    try:
        table().update_item(
            Key={"pk": pk},
            UpdateExpression="ADD #n :one SET #t = if_not_exists(#t, :ttl)",
            ConditionExpression=Attr("n").not_exists() | Attr("n").lt(limit),
            ExpressionAttributeNames={"#n": "n", "#t": "ttl"},
            ExpressionAttributeValues={":one": 1, ":ttl": int(time.time()) + COUNTER_TTL_SECONDS},
        )
        return True
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return False
        raise


def take_reading_slot(key_id_b64: str, per_device_limit: int, global_limit: int) -> str | None:
    """Returns None if this request may call Claude, else which limit was hit.

    The device counter is checked first so one busy device can't use up the global budget
    with rejected requests.
    """
    day = _today()
    if not _take(f"day#{day}#dev#{key_id_b64}", per_device_limit):
        return "device"
    if not _take(f"day#{day}#all", global_limit):
        return "global"
    return None

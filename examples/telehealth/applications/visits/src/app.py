"""Tendwell Visits: patients find an open slot and book a video visit.

One image serves both roles. Requests from the HTTP API book visits; batches
from the reminders queue send the reminder for each booking.
"""

import json
import os
import uuid
from datetime import datetime, timedelta, timezone

import boto3
from boto3.dynamodb.conditions import Key

table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])
sqs = boto3.client("sqs")

CLINICIANS = ["Dr. Amara Okafor", "Dr. Luis Herrera", "Nurse Practitioner Kim Tran"]


def respond(status, body):
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body, default=str),
    }


def open_slots():
    items = table.query(KeyConditionExpression=Key("pk").eq("SLOT"))["Items"]
    if not items:
        items = seed_slots()
    return [i for i in items if not i.get("booked")]


# A new environment has an empty table; give it a day of slots so the demo
# has something to book.
def seed_slots():
    start = (datetime.now(timezone.utc) + timedelta(days=1)).replace(hour=14, minute=0, second=0, microsecond=0)
    items = []
    with table.batch_writer() as batch:
        for n in range(12):
            at = start + timedelta(minutes=30 * n)
            item = {
                "pk": "SLOT",
                "sk": at.isoformat(),
                "clinician": CLINICIANS[n % len(CLINICIANS)],
                "starts_at": at.isoformat(),
                "booked": False,
            }
            batch.put_item(Item=item)
            items.append(item)
    return items


def book(body):
    slot = body.get("slot")
    patient = body.get("patient")
    if not slot or not patient:
        return respond(400, {"error": "slot and patient are required"})
    try:
        table.update_item(
            Key={"pk": "SLOT", "sk": slot},
            UpdateExpression="SET booked = :t",
            ConditionExpression="attribute_exists(pk) AND booked = :f",
            ExpressionAttributeValues={":t": True, ":f": False},
        )
    except table.meta.client.exceptions.ConditionalCheckFailedException:
        return respond(409, {"error": "slot is taken or doesn't exist"})

    appointment = {
        "pk": "APPT",
        "sk": str(uuid.uuid4()),
        "slot": slot,
        "patient": patient,
        "status": "booked",
        "booked_at": datetime.now(timezone.utc).isoformat(),
    }
    table.put_item(Item=appointment)
    sqs.send_message(QueueUrl=os.environ["QUEUE_URL"], MessageBody=json.dumps(appointment))
    return respond(201, appointment)


def appointments():
    return table.query(KeyConditionExpression=Key("pk").eq("APPT"))["Items"]


def appointment(appointment_id):
    item = table.get_item(Key={"pk": "APPT", "sk": appointment_id}).get("Item")
    return respond(200, item) if item else respond(404, {"error": "not found"})


def send_reminders(records):
    for record in records:
        appt = json.loads(record["body"])
        print(json.dumps({"reminder": "sent", "patient": appt["patient"], "slot": appt["slot"]}))
    return {}


def handler(event, context):
    if "Records" in event:
        return send_reminders(event["Records"])

    route = event.get("routeKey", "")
    params = event.get("pathParameters") or {}

    if route == "GET /health":
        return respond(200, {"ok": True})
    if route == "GET /slots":
        return respond(200, open_slots())
    if route == "GET /appointments":
        return respond(200, appointments())
    if route == "GET /appointments/{id}":
        return appointment(params["id"])
    if route == "POST /appointments":
        return book(json.loads(event.get("body") or "{}"))
    if route == "GET /reminders":
        return respond(200, {"role": "reminders"})
    return respond(404, {"error": f"no route for {route}"})

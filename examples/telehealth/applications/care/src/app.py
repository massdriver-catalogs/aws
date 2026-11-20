"""Tendwell Care: the clinician portal.

Clinicians see the day's booked visits, open a patient's chart, and close an
encounter with a visit note. Billing reads closed encounters to file claims.
"""

import json
import os
import uuid

import boto3
import psycopg
import redis
import requests
from flask import Flask, jsonify, request
from psycopg.rows import dict_row

app = Flask(__name__)
cache = redis.Redis.from_url(os.environ["REDIS_URL"], decode_responses=True) if os.environ.get("REDIS_URL") else None
s3 = boto3.client("s3")
VISITS_URL = os.environ["VISITS_URL"].rstrip("/")


def db():
    return psycopg.connect(row_factory=dict_row, autocommit=True)


def migrate():
    with db() as conn:
        conn.execute(
            """
            CREATE TABLE IF NOT EXISTS encounters (
              id uuid PRIMARY KEY,
              appointment_id text NOT NULL,
              patient text NOT NULL,
              clinician text NOT NULL,
              diagnosis_code text NOT NULL,
              note_key text NOT NULL,
              status text NOT NULL DEFAULT 'closed',
              closed_at timestamptz NOT NULL DEFAULT now()
            )
            """
        )


migrate()


@app.get("/health")
def health():
    return {"ok": True}


# The visit list changes a few times an hour, and every clinician opens it at
# the start of their shift; a short cache keeps that off the Visits API.
@app.get("/")
def today():
    cached = cache.get("visits") if cache else None
    if cached:
        visits = json.loads(cached)
    else:
        visits = requests.get(f"{VISITS_URL}/appointments", timeout=5).json()
        if cache:
            cache.setex("visits", 30, json.dumps(visits))
    return jsonify({"service": "care", "visits_api": VISITS_URL, "visits": visits})


@app.get("/patients/<patient>/chart")
def chart(patient):
    with db() as conn:
        rows = conn.execute(
            "SELECT * FROM encounters WHERE patient = %s ORDER BY closed_at DESC", (patient,)
        ).fetchall()
    return jsonify({"patient": patient, "encounters": rows})


@app.post("/encounters")
def close_encounter():
    body = request.get_json(force=True)
    for field in ("appointment_id", "patient", "clinician", "diagnosis_code", "note"):
        if not body.get(field):
            return {"error": f"{field} is required"}, 400

    encounter_id = uuid.uuid4()
    note_key = f"notes/{body['patient']}/{encounter_id}.txt"
    s3.put_object(
        Bucket=os.environ["BUCKET_NAME"],
        Key=note_key,
        Body=body["note"].encode(),
    )
    with db() as conn:
        row = conn.execute(
            """
            INSERT INTO encounters (id, appointment_id, patient, clinician, diagnosis_code, note_key)
            VALUES (%s, %s, %s, %s, %s, %s) RETURNING *
            """,
            (encounter_id, body["appointment_id"], body["patient"], body["clinician"], body["diagnosis_code"], note_key),
        ).fetchone()
    return jsonify(row), 201


@app.get("/encounters")
def encounters():
    since = request.args.get("since", "1970-01-01T00:00:00Z")
    with db() as conn:
        rows = conn.execute(
            "SELECT id, patient, clinician, diagnosis_code, closed_at FROM encounters WHERE closed_at > %s ORDER BY closed_at",
            (since,),
        ).fetchall()
    return jsonify(rows)

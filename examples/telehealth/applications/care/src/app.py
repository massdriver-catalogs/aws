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
from flask import Flask, jsonify, redirect, render_template_string, request
from psycopg.rows import dict_row

app = Flask(__name__)
cache = redis.Redis.from_url(os.environ["REDIS_URL"], decode_responses=True) if os.environ.get("REDIS_URL") else None
s3 = boto3.client("s3")
VISITS_URL = os.environ["VISITS_URL"].rstrip("/")

DIAGNOSES = {"Z00.00": "Annual wellness exam", "J06.9": "Upper respiratory infection", "F41.1": "Generalized anxiety"}
PATIENTS = ["Maya Chen", "Jordan Ellis", "Priya Nair", "Sam Whitaker", "Rosa Delgado", "Theo Brooks"]


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
    if not request.accept_mimetypes.accept_html:
        return jsonify({"service": "care", "visits_api": VISITS_URL, "visits": visits})

    slots = requests.get(f"{VISITS_URL}/slots", timeout=5).json()
    with db() as conn:
        closed = conn.execute(
            "SELECT patient, clinician, diagnosis_code, appointment_id, closed_at FROM encounters ORDER BY closed_at DESC LIMIT 20"
        ).fetchall()
    done = {e["appointment_id"] for e in closed}
    return render_template_string(
        PORTAL,
        visits=[v for v in sorted(visits, key=lambda v: v["slot"]) if v["sk"] not in done],
        slots=sorted(slots, key=lambda s: s["starts_at"])[:6],
        closed=closed,
        cached=bool(cached),
        visits_url=VISITS_URL,
        environment=os.environ.get("MD_ENVIRONMENT", "dev"),
        codes=DIAGNOSES,
        patients=PATIENTS,
    )


@app.post("/book")
def book():
    requests.post(
        f"{VISITS_URL}/appointments",
        json={"slot": request.form["slot"], "patient": request.form["patient"]},
        timeout=5,
    )
    if cache:
        cache.delete("visits")
    return redirect("/")


@app.post("/close")
def close_from_portal():
    form = request.form
    record_encounter(form["appointment_id"], form["patient"], form["clinician"], form["diagnosis_code"], form["note"])
    return redirect("/")


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

    row = record_encounter(body["appointment_id"], body["patient"], body["clinician"], body["diagnosis_code"], body["note"])
    return jsonify(row), 201


def record_encounter(appointment_id, patient, clinician, diagnosis_code, note):
    encounter_id = uuid.uuid4()
    note_key = f"notes/{patient}/{encounter_id}.txt"
    s3.put_object(Bucket=os.environ["BUCKET_NAME"], Key=note_key, Body=note.encode())
    with db() as conn:
        return conn.execute(
            """
            INSERT INTO encounters (id, appointment_id, patient, clinician, diagnosis_code, note_key)
            VALUES (%s, %s, %s, %s, %s, %s) RETURNING *
            """,
            (encounter_id, appointment_id, patient, clinician, diagnosis_code, note_key),
        ).fetchone()


@app.get("/encounters")
def encounters():
    since = request.args.get("since", "1970-01-01T00:00:00Z")
    with db() as conn:
        rows = conn.execute(
            "SELECT id, patient, clinician, diagnosis_code, closed_at FROM encounters WHERE closed_at > %s ORDER BY closed_at",
            (since,),
        ).fetchall()
    return jsonify(rows)


PORTAL = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Tendwell Care</title>
<style>
:root{--teal:#0B6E6C;--mint:#18B7A0;--ink:#13302f;--muted:#5d7472;--line:#dbe7e5;--bg:#f4f8f7}
*{box-sizing:border-box}body{margin:0;font:15px/1.5 system-ui,-apple-system,sans-serif;color:var(--ink);background:var(--bg)}
header{background:linear-gradient(120deg,var(--teal),var(--mint));color:#fff;padding:20px 24px}
header h1{margin:0;font-size:22px}header p{margin:4px 0 0;opacity:.85}
.pill{display:inline-block;background:rgba(255,255,255,.2);border-radius:99px;padding:2px 10px;font-size:12px;margin-left:8px}
main{max-width:1100px;margin:0 auto;padding:20px 16px;display:grid;gap:16px;grid-template-columns:repeat(auto-fit,minmax(320px,1fr))}
section{background:#fff;border:1px solid var(--line);border-radius:12px;padding:16px}
h2{margin:0 0 12px;font-size:16px}.muted{color:var(--muted);font-size:13px}
.row{border-top:1px solid var(--line);padding:10px 0}.row:first-of-type{border-top:0}
input,select,textarea{font:inherit;width:100%;padding:6px 8px;border:1px solid var(--line);border-radius:8px;margin-top:6px}
button{font:inherit;background:var(--teal);color:#fff;border:0;border-radius:8px;padding:6px 14px;margin-top:8px;cursor:pointer}
.flow{grid-column:1/-1;display:flex;gap:8px;align-items:center;flex-wrap:wrap;font-size:13px}
.node{background:#fff;border:1px solid var(--line);border-radius:10px;padding:8px 12px}.node b{color:var(--teal)}
</style></head><body>
<header><h1>Tendwell Care <span class="pill">{{ environment }}</span></h1><p>Today's video visits, charts and visit notes</p></header>
<main>
<div class="flow">
<div class="node"><b>Visits</b> · Lambda + DynamoDB + SQS</div>→
<div class="node"><b>Care</b> · ECS + Postgres + Valkey{{ " (cache hit)" if cached else "" }} + S3</div>→
<div class="node"><b>Billing</b> · ECS + MariaDB + S3</div>
</div>
<section><h2>Open slots</h2><p class="muted">From the Visits API at {{ visits_url }}</p>
{% for s in slots %}<form class="row" method="post" action="/book">
<div><b>{{ s.starts_at[11:16] }} UTC</b> · {{ s.clinician }}</div>
<input type="hidden" name="slot" value="{{ s.sk }}">
<select name="patient">{% for p in patients %}<option>{{ p }}</option>{% endfor %}</select>
<button>Book visit</button></form>{% else %}<p class="muted">No open slots.</p>{% endfor %}
</section>
<section><h2>Booked visits</h2>
{% for v in visits %}<form class="row" method="post" action="/close">
<div><b>{{ v.patient }}</b> · {{ v.slot[11:16] }} UTC</div>
<input type="hidden" name="appointment_id" value="{{ v.sk }}"><input type="hidden" name="patient" value="{{ v.patient }}">
<input type="hidden" name="clinician" value="Dr. Amara Okafor">
<select name="diagnosis_code">{% for code, label in codes.items() %}<option value="{{ code }}">{{ code }} · {{ label }}</option>{% endfor %}</select>
<textarea name="note" rows="2" required>Video visit completed. Plan reviewed with patient.</textarea>
<button>Close visit</button></form>{% else %}<p class="muted">Nothing booked. Book a slot to start.</p>{% endfor %}
</section>
<section><h2>Closed encounters</h2><p class="muted">Postgres; notes in S3. Billing turns these into claims.</p>
{% for e in closed %}<div class="row"><b>{{ e.patient }}</b> · {{ e.diagnosis_code }}<div class="muted">{{ e.clinician }} · {{ e.closed_at.strftime("%b %d %H:%M") }} UTC</div></div>
{% else %}<p class="muted">None yet.</p>{% endfor %}
</section>
</main></body></html>"""

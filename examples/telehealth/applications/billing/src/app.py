"""Tendwell Billing: turns closed encounters into insurance claims.

Came over with the Clearpath acquisition, which is why it runs on MySQL. It
pulls closed encounters from Care, prices them, and writes a claim file for
the clearinghouse to S3.
"""

import hashlib
import hmac
import json
import os
import uuid
from datetime import datetime, timedelta, timezone

import boto3
import pymysql
import requests
from flask import Flask, jsonify, redirect, render_template_string, request

app = Flask(__name__)
s3 = boto3.client("s3")
CARE_URL = os.environ["CARE_URL"].rstrip("/")
# The clearinghouse rejects claim files that aren't signed with Tendwell's key.
CLEARINGHOUSE_KEY = os.environ.get("CLEARINGHOUSE_API_KEY", "")

# Illustrative prices per diagnosis code; a real fee schedule comes from payer contracts.
FEES = {"Z00.00": 145_00, "J06.9": 95_00, "F41.1": 160_00}
DEFAULT_FEE = 110_00


def db():
    return pymysql.connect(
        host=os.environ["MYSQL_HOST"],
        port=int(os.environ["MYSQL_PORT"]),
        user=os.environ["MYSQL_USER"],
        password=os.environ["MYSQL_PASSWORD"],
        database=os.environ["MYSQL_DATABASE"],
        ssl={"ca": "/etc/ssl/rds.pem"},
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True,
    )


def migrate():
    with db() as conn, conn.cursor() as cur:
        cur.execute(
            """
            CREATE TABLE IF NOT EXISTS claims (
              id CHAR(36) PRIMARY KEY,
              encounter_id CHAR(36) NOT NULL UNIQUE,
              patient VARCHAR(255) NOT NULL,
              diagnosis_code VARCHAR(16) NOT NULL,
              amount_cents INT NOT NULL,
              export_key VARCHAR(512) NOT NULL,
              created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
            )
            """
        )


migrate()


@app.get("/health")
def health():
    return {"ok": True}


@app.get("/")
def summary():
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) AS claims, COALESCE(SUM(amount_cents), 0) AS cents FROM claims")
        totals = cur.fetchone()
        if not request.accept_mimetypes.accept_html:
            return jsonify({"service": "billing", "care_api": CARE_URL, "claims": totals["claims"], "billed": totals["cents"] / 100})
        cur.execute("SELECT * FROM claims ORDER BY created_at DESC LIMIT 50")
        rows = cur.fetchall()
    return render_template_string(
        LEDGER, totals=totals, claims=rows, care_url=CARE_URL, filed=request.args.get("filed"),
        key_hint=CLEARINGHOUSE_KEY[-4:] if CLEARINGHOUSE_KEY else None,
        environment=os.environ.get("MD_ENVIRONMENT", "dev"),
    )


@app.get("/claims")
def claims():
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT * FROM claims ORDER BY created_at DESC LIMIT 100")
        return jsonify(cur.fetchall())


@app.post("/claims/run")
def run():
    with db() as conn, conn.cursor() as cur:
        cur.execute("SELECT MAX(created_at) AS last FROM claims")
        last = cur.fetchone()["last"]
        # An encounter can close while a run is in flight, after Care answered
        # but before the claim is saved. Looking back an hour catches it; the
        # unique encounter_id keeps the overlap from filing twice.
        since = (last.replace(tzinfo=timezone.utc) - timedelta(hours=1)).isoformat() if last else "1970-01-01T00:00:00Z"

        encounters = requests.get(f"{CARE_URL}/encounters", params={"since": since}, timeout=10).json()
        filed = []
        for enc in encounters:
            claim_id = str(uuid.uuid4())
            amount = FEES.get(enc["diagnosis_code"], DEFAULT_FEE)
            key = f"claims/{datetime.now(timezone.utc):%Y/%m/%d}/{claim_id}.json"
            claim = {"claim_id": claim_id, "amount_cents": amount, **enc}
            if CLEARINGHOUSE_KEY:
                body = json.dumps(claim, default=str, sort_keys=True).encode()
                claim["signature"] = hmac.new(CLEARINGHOUSE_KEY.encode(), body, hashlib.sha256).hexdigest()
            cur.execute(
                "INSERT IGNORE INTO claims (id, encounter_id, patient, diagnosis_code, amount_cents, export_key) VALUES (%s, %s, %s, %s, %s, %s)",
                (claim_id, enc["id"], enc["patient"], enc["diagnosis_code"], amount, key),
            )
            if cur.rowcount == 0:
                continue
            s3.put_object(
                Bucket=os.environ["BUCKET_NAME"],
                Key=key,
                Body=json.dumps(claim, default=str).encode(),
            )
            filed.append(claim)
    if request.accept_mimetypes.accept_html and not request.is_json:
        return redirect(f"/?filed={len(filed)}")
    return jsonify({"filed": len(filed), "claims": filed})


LEDGER = """<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Tendwell Billing</title>
<style>
:root{--teal:#0B6E6C;--mint:#18B7A0;--ink:#13302f;--muted:#5d7472;--line:#dbe7e5;--bg:#f4f8f7}
*{box-sizing:border-box}body{margin:0;font:15px/1.5 system-ui,-apple-system,sans-serif;color:var(--ink);background:var(--bg)}
header{background:linear-gradient(120deg,#123f4f,var(--teal));color:#fff;padding:20px 24px}
header h1{margin:0;font-size:22px}header p{margin:4px 0 0;opacity:.85}
.pill{display:inline-block;background:rgba(255,255,255,.2);border-radius:99px;padding:2px 10px;font-size:12px;margin-left:8px}
main{max-width:1000px;margin:0 auto;padding:20px 16px}
.stats{display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:12px;margin-bottom:16px}
.stat,section{background:#fff;border:1px solid var(--line);border-radius:12px;padding:16px}
.stat b{display:block;font-size:28px;color:var(--teal)}.muted{color:var(--muted);font-size:13px}
table{width:100%;border-collapse:collapse;font-size:14px}th,td{text-align:left;padding:8px 6px;border-top:1px solid var(--line)}
th{color:var(--muted);font-weight:600;border-top:0}td.r,th.r{text-align:right}
button{font:inherit;background:var(--teal);color:#fff;border:0;border-radius:8px;padding:8px 16px;cursor:pointer}
.note{background:#e6f6f2;border-radius:8px;padding:8px 12px;margin-bottom:12px}
</style></head><body>
<header><h1>Tendwell Billing <span class="pill">{{ environment }}</span></h1><p>Claims for closed encounters, filed to the clearinghouse</p></header>
<main>
{% if filed is not none %}<div class="note">Filed {{ filed }} new claim{{ "" if filed == "1" else "s" }}.</div>{% endif %}
<div class="stats">
<div class="stat"><b>{{ totals.claims }}</b><span class="muted">claims filed</span></div>
<div class="stat"><b>${{ "{:,.2f}".format(totals.cents / 100) }}</b><span class="muted">billed</span></div>
<div class="stat"><b>{% if key_hint %}Connected{% else %}Not connected{% endif %}</b><span class="muted">{% if key_hint %}Clearinghouse key ending {{ key_hint }}{% else %}Set the Clearinghouse API key secret in Massdriver{% endif %}</span></div>
<div class="stat"><form method="post" action="/claims/run"><button>Run claims</button></form><span class="muted">Pulls closed encounters from {{ care_url }}</span></div>
</div>
<section><table><tr><th>Patient</th><th>Diagnosis</th><th class="r">Amount</th><th>Claim file (S3)</th><th>Filed</th></tr>
{% for c in claims %}<tr><td>{{ c.patient }}</td><td>{{ c.diagnosis_code }}</td><td class="r">${{ "{:,.2f}".format(c.amount_cents / 100) }}</td><td class="muted">{{ c.export_key }}</td><td class="muted">{{ c.created_at.strftime("%b %d %H:%M") }}</td></tr>
{% else %}<tr><td colspan="5" class="muted">No claims yet. Close a visit in Care, then run claims.</td></tr>{% endfor %}
</table></section>
</main></body></html>"""

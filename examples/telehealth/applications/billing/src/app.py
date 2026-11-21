"""Tendwell Billing: turns closed encounters into insurance claims.

Came over with the Clearpath acquisition, which is why it runs on MySQL. It
pulls closed encounters from Care, prices them, and writes a claim file for
the clearinghouse to S3.
"""

import json
import os
import uuid
from datetime import datetime, timezone

import boto3
import pymysql
import requests
from flask import Flask, jsonify

app = Flask(__name__)
s3 = boto3.client("s3")
CARE_URL = os.environ["CARE_URL"].rstrip("/")

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
    return jsonify({"service": "billing", "care_api": CARE_URL, "claims": totals["claims"], "billed": totals["cents"] / 100})


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
        since = last.replace(tzinfo=timezone.utc).isoformat() if last else "1970-01-01T00:00:00Z"

        encounters = requests.get(f"{CARE_URL}/encounters", params={"since": since}, timeout=10).json()
        filed = []
        for enc in encounters:
            claim_id = str(uuid.uuid4())
            amount = FEES.get(enc["diagnosis_code"], DEFAULT_FEE)
            key = f"claims/{datetime.now(timezone.utc):%Y/%m/%d}/{claim_id}.json"
            claim = {"claim_id": claim_id, "amount_cents": amount, **enc}
            s3.put_object(
                Bucket=os.environ["BUCKET_NAME"],
                Key=key,
                Body=json.dumps(claim, default=str).encode(),
            )
            cur.execute(
                "INSERT IGNORE INTO claims (id, encounter_id, patient, diagnosis_code, amount_cents, export_key) VALUES (%s, %s, %s, %s, %s, %s)",
                (claim_id, enc["id"], enc["patient"], enc["diagnosis_code"], amount, key),
            )
            filed.append(claim)
    return jsonify({"filed": len(filed), "claims": filed})

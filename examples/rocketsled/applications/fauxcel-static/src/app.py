import base64
import mimetypes
import os

import boto3
from botocore.exceptions import ClientError

s3 = boto3.client("s3")
BUCKET = os.environ["SITE_BUCKET"]

# Hashed asset names never change, so browsers may keep them; pages must be
# revalidated or a new deploy wouldn't show.
LONG_CACHE = "public, max-age=31536000, immutable"
NO_CACHE = "public, max-age=0, must-revalidate"


def fetch(key):
    try:
        return s3.get_object(Bucket=BUCKET, Key=key)
    except ClientError as e:
        if e.response["Error"]["Code"] in ("NoSuchKey", "AccessDenied"):
            return None
        raise


def handler(event, _context):
    path = event.get("rawPath") or "/"
    key = path.lstrip("/")
    if key == "" or key.endswith("/"):
        key += "index.html"

    obj = fetch(key)
    # A path with no extension is a client-side route in a single-page app.
    if obj is None and "." not in key.rsplit("/", 1)[-1]:
        obj = fetch(key.rstrip("/") + "/index.html") or fetch("index.html")
        key = "index.html" if obj else key
    if obj is None:
        missing = fetch("404.html")
        body = missing["Body"].read() if missing else b"Not found"
        return {"statusCode": 404, "headers": {"content-type": "text/html"}, "body": body.decode()}

    body = obj["Body"].read()
    ctype = obj.get("ContentType") or mimetypes.guess_type(key)[0] or "application/octet-stream"
    immutable = "/assets/" in f"/{key}" or "/_next/static/" in f"/{key}"
    return {
        "statusCode": 200,
        "headers": {
            "content-type": ctype,
            "cache-control": LONG_CACHE if immutable else NO_CACHE,
            "etag": obj.get("ETag", ""),
        },
        "isBase64Encoded": True,
        "body": base64.b64encode(body).decode(),
    }

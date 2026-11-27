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


# A new site has no files yet; it still answers, and says how to fill it.
PLACEHOLDER = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1"><title>{name} · Fauxcel</title>
<style>html,body{{margin:0;height:100%;background:#000;color:#fff;font:15px/1.7 ui-monospace,SFMono-Regular,Menlo,monospace}}
main{{min-height:100%;display:grid;place-content:center;gap:24px;padding:32px;box-sizing:border-box}}
svg{{width:40px;height:40px}}h1{{margin:0;font-weight:400;font-size:28px;letter-spacing:-.03em}}
p{{margin:0;color:#a1a1a1}}code{{color:#fff;border:1px solid #333;padding:10px 14px;display:block;overflow-x:auto}}</style></head>
<body><main><svg viewBox="0 0 64 64"><path d="M32 6 54 44 32 58 10 44Z" fill="#fff"/></svg>
<h1>{name}</h1><p>Deployed. Nothing to show yet. That's fine.</p>
<code>aws s3 sync dist/ s3://{bucket}/</code></main></body></html>"""


def placeholder(_event):
    # Functions are named <project>-<environment>-site-<suffix>.
    parts = os.environ.get("AWS_LAMBDA_FUNCTION_NAME", "").split("-")
    name = parts[1] if len(parts) > 2 else "Your site"
    return PLACEHOLDER.format(name=name, bucket=BUCKET)


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
    if obj is None and key == "index.html":
        return {"statusCode": 200, "headers": {"content-type": "text/html", "cache-control": NO_CACHE}, "body": placeholder(event)}
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

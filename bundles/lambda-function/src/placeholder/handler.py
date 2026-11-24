import json
import os
import socket
from urllib.parse import urlparse


def reachable(host, port):
    try:
        with socket.create_connection((host, int(port)), timeout=2):
            return "reachable"
    except Exception as e:
        return "unreachable: " + str(e)


def handler(event, context):
    body = {
        "message": "Placeholder function. Set a container image to replace it.",
        "route": event.get("routeKey"),
        "path": event.get("rawPath"),
    }

    connected = {}
    if os.environ.get("PGHOST"):
        connected["postgres"] = reachable(os.environ["PGHOST"], os.environ.get("PGPORT", "5432"))
    if os.environ.get("MYSQL_HOST"):
        connected["mariadb"] = reachable(os.environ["MYSQL_HOST"], os.environ.get("MYSQL_PORT", "3306"))
    if os.environ.get("REDIS_URL"):
        cache = urlparse(os.environ["REDIS_URL"])
        connected["cache"] = reachable(cache.hostname, cache.port)
    for name in ("TABLE_NAME", "BUCKET_NAME", "QUEUE_URL"):
        if os.environ.get(name):
            connected[name] = os.environ[name]
    if connected:
        body["connected"] = connected

    if "Records" in event:
        print(json.dumps({"received_messages": len(event["Records"])}))
        return {}

    return {
        "statusCode": 200,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body),
    }

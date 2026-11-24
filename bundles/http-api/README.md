# HTTP API

An API Gateway HTTP API with one stage, `$default`, that deploys every change right away. It has no routes of its own: each connected Lambda function adds the routes it answers, so one API can sit in front of several functions.

## What it needs

- An AWS role to deploy with.
- Optional: the environment's **DNS zone**, to answer on your own domain.

## What it makes

- The API, its `$default` stage, and an access log group.
- Alarms when more than 5% of requests fail with a 5xx error, and when traffic runs above 80% of **Steady requests per second**.
- With a DNS zone and a **Subdomain**: a custom domain such as `api.dev.example.com`, using the zone's certificate, and the DNS record that points it at the API.

The API's address goes to connected functions. With a custom domain, the address is `https://<subdomain>.<zone domain>`; without one, it's the AWS address (`https://<id>.execute-api.<region>.amazonaws.com`).

## Custom domain

Set **Subdomain** (for example `api`) and connect the DNS zone. The API must be in the same region as the zone, because the certificate only works there; the deploy fails with a clear message if they differ. The AWS address keeps working too.

## Request limits

**Steady requests per second** and **Burst requests** apply to every route. Requests above them get `429 Too Many Requests` and never reach a function, which also caps what a misbehaving client can cost.

## CORS

Only needed when a web page on a different origin calls the API from the browser. API Gateway answers the browser's preflight request itself.

## Logs

Each request writes one JSON line to `/aws/apigateway/<name>`: route, status, latency, and the integration error if the function failed.

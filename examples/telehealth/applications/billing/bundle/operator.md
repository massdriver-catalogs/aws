---
templating: mustache
---
# Tendwell Billing

## Run claims now

```bash
curl -H 'accept: application/json' -s -X POST https://{{params.subdomain}}.{{dependencies.dns.domain}}/claims/run | jq '.filed'
```

## A run files nothing

Billing only files encounters Care closed after the last claim. Check Care has some:

```bash
curl -s "{{dependencies.care.url}}/encounters" | jq length
```

## Tasks fail with `require_secure_transport`

The database only accepts TLS. The image connects with the RDS certificate bundle at `/etc/ssl/rds.pem`; an image built without it can't connect. Rebuild from `examples/telehealth/applications/billing/src`.

## Ship a new version

```bash
cd examples/telehealth && ./deploy.sh ship billing <environment>
```

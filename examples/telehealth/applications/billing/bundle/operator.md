---
templating: mustache
---
# Tendwell Billing

{{#resources.billing}}
## Run claims now

```bash
curl -s -X POST -H 'accept: application/json' {{resources.billing.url}}/claims/run | jq '.filed'
```

## A run files nothing

Billing files encounters Care has closed since its last claim. Check Care has some:

```bash
curl -s "{{dependencies.care.url}}/encounters" | jq length
```

Zero means nobody has closed a visit in Care. An error means Care is down; see Care's guide.
{{/resources.billing}}

## Claims aren't signed

The ledger shows **Not connected** when the **Clearinghouse API key** secret isn't set. Claims are still filed, unsigned. Set the secret on this instance and deploy; the tasks restart with it.

## Read the logs

```bash
aws logs tail /ecs/{{params.md_metadata.name_prefix}} --region {{dependencies.cluster.region}} --since 30m --follow
```

## Server errors or tasks failing health checks

Billing creates its table in MariaDB when it starts, so a task that can't reach the database never passes its health check. A 5xx on a page usually means MariaDB or Care. Look for:

- **`require_secure_transport` or `SSL`:** the image is missing the RDS certificate bundle at `/etc/ssl/rds.pem`. Rebuild from `examples/telehealth/applications/billing/src`.
- **`Can't connect to MySQL server` or a timeout:** the task isn't in the ledger's client security group. Check the ledger is linked to this app, then deploy.
- **`Access denied for user`:** the password changed. Deploy this instance so ECS reads the new one.
- **`ConnectionError` to Care:** see Care's guide.

## CPU high or Memory high

Run claims is the only heavy request. Raise **Task size** if memory alarms during runs, or **Most tasks when busy** for CPU.

## Ship a new version

```bash
cd examples/telehealth && ./deploy.sh ship billing <environment>
```

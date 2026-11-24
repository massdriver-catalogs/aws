---
templating: mustache
---
# Tendwell Care

{{#resources.care}}
## Close an encounter by hand

```bash
curl -s -X POST {{resources.care.url}}/encounters \
  -H 'content-type: application/json' \
  -d '{"appointment_id": "demo", "patient": "demo-patient", "clinician": "Dr. Amara Okafor", "diagnosis_code": "Z00.00", "note": "Annual wellness visit."}' | jq
```
{{/resources.care}}

## The visit list is empty or stale

The portal caches the Visits API's list in Valkey for 30 seconds. If it stays empty, call Visits directly:

```bash
curl -s {{dependencies.visits.url}}/appointments | jq length
```

An error there is a Visits problem; see that instance's guide. Zero means nobody has booked; book one from the portal.

## Read the logs

```bash
aws logs tail /ecs/{{params.md_metadata.name_prefix}} --region {{dependencies.cluster.region}} --since 30m --follow
```

## Server errors, 502 or 503

Care creates its table in PostgreSQL when it starts, so a task that can't reach the database never passes its health check and the portal returns 503. Look for:

- **`connection refused` or a timeout:** the task isn't in the Charts database's client security group. Check Charts is linked to this app, then deploy.
- **`certificate verify failed`:** the image's RDS certificate bundle is out of date. Rebuild it.
- **`password authentication failed`:** the password changed. Deploy this instance so ECS reads the new one.
- **`AccessDenied` on S3:** visit notes can't be written. Check Documents is linked to this app, then deploy.
- **`ConnectionError` to Visits:** see the Visits guide.

## Slow responses

Every page calls the Visits API and PostgreSQL. A cache miss doubles the Visits calls, so check Valkey (Sessions) is linked and reachable: `Error connecting to` in the logs means it isn't.

## Ship a new version

```bash
cd examples/telehealth && ./deploy.sh ship care <environment>
```

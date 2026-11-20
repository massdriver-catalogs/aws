---
templating: mustache
---
# Tendwell Care

## Close an encounter by hand

```bash
curl -s -X POST https://{{params.subdomain}}.{{dependencies.dns.domain}}/encounters \
  -H 'content-type: application/json' \
  -d '{"appointment_id": "demo", "patient": "demo-patient", "clinician": "Dr. Amara Okafor", "diagnosis_code": "Z00.00", "note": "Annual wellness visit."}' | jq
```

## The visit list is empty or stale

The portal caches the Visits API's list for 30 seconds. If it stays empty, call Visits directly:

```bash
curl -s {{dependencies.visits.url}}/appointments | jq length
```

An error there is a Visits problem; see that instance's operator guide.

## 502 or 503 from the portal

The tasks are failing their health check on `/health`, usually because they can't reach PostgreSQL at startup. Read the logs:

```bash
aws logs tail /ecs/{{params.md_metadata.name_prefix}} --region {{dependencies.cluster.region}} --since 30m
```

`connection refused` or a timeout means the database's client security group isn't on the task; redeploy after connecting the database. `certificate verify failed` means the image's RDS certificate bundle is out of date; rebuild it.

## Ship a new version

```bash
cd examples/telehealth && ./deploy.sh ship care <environment>
```

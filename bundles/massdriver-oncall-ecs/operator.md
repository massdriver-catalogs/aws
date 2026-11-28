---
templating: mustache
---
# On Call

- **Runs on:** `{{dependencies.ecs_cluster.name}}`, {{dependencies.ecs_cluster.region}}
- **Image:** `{{params.image.repository}}:{{params.image.tag}}`
- **Settings:**

```yaml
{{{params.config}}}
```

## An environment's on-call widget is empty

Each interval, the automation reads who is on call in PagerDuty or incident.io for each route and writes the people list to the `md/v1/oncall` key of each environment in the route.

- **No environment gets the entry:** the automation is down. See **Read the logs**.
- **One environment has none:** `oncall query failed` names the route and the provider's error. `oncall write failed` carries the server's reason.
- **To try the widget without a provider:** give a route a `static` list.

## Read the logs

The service name is cut short to fit AWS limits, so look it up:

```bash
SVC=$(aws ecs list-services --region {{dependencies.ecs_cluster.region}} --cluster {{dependencies.ecs_cluster.name}} \
  --query "serviceArns[?ends_with(@, '-oncall')] | [0]" --output text | awk -F/ '{print $NF}')
aws logs tail /ecs/$SVC --region {{dependencies.ecs_cluster.region}} --since 30m --follow
```

`oncall started` with the interval means the settings loaded.

## Errors

- **`oncall query failed` with `401` or `403`:** set a new `PAGERDUTY_TOKEN` (a read-only REST API key) or `INCIDENT_IO_API_KEY` (with `schedules.view` and `escalation_paths.view`) and deploy.
- **`oncall write failed` with `forbidden`:** the service account needs `stash:write` on that environment.
- **`401` or `unauthorized` from Massdriver:** the service account's key is gone. Give the **service_account** resource a new key and deploy.

## The task won't start or keeps restarting

```bash
aws ecs describe-services --region {{dependencies.ecs_cluster.region}} --cluster {{dependencies.ecs_cluster.name}} --services $SVC \
  --query 'services[0].events[:10].[createdAt,message]' --output text
```

- **`CannotPullContainerError`:** the image tag `{{params.image.tag}}` doesn't exist. Pick a published tag and deploy.
- **The log stops right after start with `unknown automation "oncall"`:** the image tag is a release without oncall. Use `latest` until a release has it.
- **The log stops right after start with `invalid config` or `a static route needs no provider token`:** the record names the key. A route with a `static` list takes no token. Fix the setting and deploy.

## Check that it answers

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://{{#params.ingress.host}}{{params.ingress.host}}{{/params.ingress.host}}{{^params.ingress.host}}{{#dependencies.ecs_cluster.zone}}oncall.{{dependencies.ecs_cluster.zone.domain}}{{/dependencies.ecs_cluster.zone}}{{/params.ingress.host}}/healthz
```

- **`503`:** no task is healthy. See **The task won't start or keeps restarting**.
- **`204`:** the automation is up.

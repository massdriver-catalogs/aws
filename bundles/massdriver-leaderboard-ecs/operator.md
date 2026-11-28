---
templating: mustache
---
# Leaderboard

- **Runs on:** `{{dependencies.ecs_cluster.name}}`, {{dependencies.ecs_cluster.region}}
- **Image:** `{{params.image.repository}}:{{params.image.tag}}`
- **Settings:**

```yaml
{{{params.config}}}
```

## An environment's leaderboard widget is empty

Each interval, the automation reads the GitHub pull requests for each route and writes the people list to the `md/v1/leaderboard` key of each environment in the route.

- **No environment gets the entry:** the automation is down. See **Read the logs**.
- **One environment has none:** `github query failed` names the repository the `GITHUB_TOKEN` secret cannot read, and `leaderboard skipped` names the route that lists it. `leaderboard write failed` carries the server's reason.
- **To try the widget without GitHub:** give a route a `static` list.

## Read the logs

The service name is cut short to fit AWS limits, so look it up:

```bash
SVC=$(aws ecs list-services --region {{dependencies.ecs_cluster.region}} --cluster {{dependencies.ecs_cluster.name}} \
  --query "serviceArns[?ends_with(@, '-leaderboard')] | [0]" --output text | awk -F/ '{print $NF}')
aws logs tail /ecs/$SVC --region {{dependencies.ecs_cluster.region}} --since 30m --follow
```

`leaderboard started` with the interval means the settings loaded.

## Errors

- **`github query failed` with `401` or `Bad credentials`:** set a new `GITHUB_TOKEN` and deploy. A fine-grained token needs `Pull requests` and `Contents` read; a classic token needs `repo` for private repositories.
- **`github query truncated`:** a route's window holds more pull requests than one query returns. Narrow the window or the repositories.
- **`leaderboard write failed` with `forbidden`:** the service account needs `stash:write` on that environment.
- **`401` or `unauthorized` from Massdriver:** the service account's key is gone. Give the **service_account** resource a new key and deploy.

## The task won't start or keeps restarting

```bash
aws ecs describe-services --region {{dependencies.ecs_cluster.region}} --cluster {{dependencies.ecs_cluster.name}} --services $SVC \
  --query 'services[0].events[:10].[createdAt,message]' --output text
```

- **`CannotPullContainerError`:** the image tag `{{params.image.tag}}` doesn't exist. Pick a published tag and deploy.
- **The log stops right after start with `unknown automation "leaderboard"`:** the image tag is a release without leaderboard. Use `latest` until a release has it.
- **The log stops right after start with `invalid config` or `a static route needs no GitHub token`:** the record names the key. A route with a `static` list takes no token. Fix the setting and deploy.

## Check that it answers

```bash
curl -s -o /dev/null -w '%{http_code}\n' https://{{#params.ingress.host}}{{params.ingress.host}}{{/params.ingress.host}}{{^params.ingress.host}}{{#dependencies.ecs_cluster.zone}}leaderboard.{{dependencies.ecs_cluster.zone.domain}}{{/dependencies.ecs_cluster.zone}}{{/params.ingress.host}}/healthz
```

- **`503`:** no task is healthy. See **The task won't start or keeps restarting**.
- **`204`:** the automation is up.

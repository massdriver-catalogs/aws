---
templating: mustache
---
# Fauxroku Ruby Dynos

{{#resources.web}}
**Open first:** {{resources.web.url}}

{{/resources.web}}
- **Dynos:** {{params.desired_count}} to {{params.max_count}} × {{params.size}} ({{params.architecture}}){{#params.spot}}, Spot{{/params.spot}}
- **Service and logs:** `{{params.md_metadata.name_prefix}}`, `/ecs/{{params.md_metadata.name_prefix}}`
- **Image:** `{{params.image_uri}}`
- **Postgres:** {{#dependencies.database}}`{{dependencies.database.hostname}}`{{/dependencies.database}}{{^dependencies.database}}none{{/dependencies.database}}
- **Key-Value Store:** {{#dependencies.cache}}`{{dependencies.cache.hostname}}`{{/dependencies.cache}}{{^dependencies.cache}}none{{/dependencies.cache}}

## Tail the logs

```bash
aws logs tail /ecs/{{params.md_metadata.name_prefix}} --region {{dependencies.cluster.region}} --since 15m --follow
```

## The URL returns 503

No web dyno is healthy.

```bash
aws ecs describe-services --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} \
  --services {{params.md_metadata.name_prefix}} --query 'services[0].[runningCount,desiredCount,events[:5].message]'
```

- **Dynos start and stop:** the app isn't listening on `PORT` ({{params.port}}), or `{{params.health_check_path}}` doesn't answer 2xx or 3xx. The stopped dyno's reason is in the events.
- **`exec format error`:** the image isn't built for {{params.architecture}}.
- **`CannotPullContainerError`:** the tag doesn't exist, or the image is in another account or region.
- **Exit 137:** out of memory. Pick a bigger **Task size**.

## Can't connect to Postgres

{{#dependencies.database}}
- **Timeout:** the dynos lost the database's client security group. Redeploy the web dynos.
- **`password authentication failed`:** the password was rotated. Redeploy so new dynos read it.
- **The client ignores `PGPASSWORD`:** some URL parsers (dj-database-url, for one) want the password in `DATABASE_URL`. Build the URL in the app from `DATABASE_URL` and `PGPASSWORD`.
{{/dependencies.database}}
{{^dependencies.database}}
No Postgres is connected, so `DATABASE_URL` is empty.
{{/dependencies.database}}

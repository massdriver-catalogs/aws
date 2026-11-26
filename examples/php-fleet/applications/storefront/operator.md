---
templating: mustache
---
# Storefront

{{#params.subdomain}}**URL:** https://{{params.subdomain}}.{{dependencies.cluster.zone.domain}}{{/params.subdomain}}{{^params.subdomain}}**URL:** none; set **Subdomain** to give it one.{{/params.subdomain}}

- **Version:** 1.4.0
- **Built on:** ecs-service
- **Size:** {{params.size}} ({{params.architecture}}), tasks: {{params.desired_count}}, Spot: {{params.spot}}
- **Cluster:** {{dependencies.cluster.name}} ({{dependencies.cluster.region}})
- **Image:** `{{params.image_uri}}`

## The page doesn't load

The page is PHP's built-in Apache serving one `index.php`. A 502 or 503 means no task passed the health check on `{{params.health_check_path}}`:

```bash
aws ecs describe-services --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} --services {{params.md_metadata.name_prefix}} \
  --query 'services[0].events[:5].[createdAt,message]' --output text
```

- **`CannotPullContainerError`:** the image tag isn't in the registry. Run `./deploy.sh image` from `examples/php-fleet`, then deploy.
- **Spot capacity:** AWS took the task back and the replacement hasn't started yet. It comes back on its own within a few minutes.
- **`Task failed ELB health checks`:** Apache isn't on port {{params.port}}. The image listens on 80; set **Container port** back to 80 and deploy.

## Read the logs

```bash
aws logs tail /ecs/{{params.md_metadata.name_prefix}} --region {{dependencies.cluster.region}} --since 15m --follow
```

## Move to the newest runtime

This version keeps the runtime it was built on. To move to the newest ecs-service, publish Storefront again with `app.runtime: ecs-service`, then put this instance on the new version and deploy:

```bash
mass instance version {{id}}@<new version>
mass instance deploy {{id}} -m "Storefront on the newest ecs-service" --follow
```

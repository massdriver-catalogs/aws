---
templating: mustache
---
# Fauxroku Worker Dynos

**Open first:** https://console.aws.amazon.com/ecs/v2/clusters/{{dependencies.cluster.name}}/services/{{params.md_metadata.name_prefix}}/health?region={{dependencies.cluster.region}}

- **Dynos:** {{params.desired_count}} to {{params.max_count}} × {{params.size}} ({{params.architecture}}){{#params.spot}}, Spot{{/params.spot}}
- **Service and logs:** `{{params.md_metadata.name_prefix}}`, `/ecs/{{params.md_metadata.name_prefix}}`
- **Image:** `{{params.image_uri}}`

## Tail the logs

```bash
aws logs tail /ecs/{{params.md_metadata.name_prefix}} --region {{dependencies.cluster.region}} --since 15m --follow
```

## Jobs pile up

```bash
aws ecs describe-services --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} \
  --services {{params.md_metadata.name_prefix}} --query 'services[0].[runningCount,desiredCount,events[:5].message]'
```

- **0 running:** see the events. On Spot, "unable to place" means no Spot capacity right now; turn off **Run on Spot** and deploy.
- **Running but idle:** the worker started the web server instead. The entrypoint must branch on `PROCESS_TYPE=worker`.
- **Can't reach the queue:** {{#dependencies.cache}}`REDIS_URL` must stay `rediss://`; the store takes TLS only.{{/dependencies.cache}}{{^dependencies.cache}}no Key-Value Store is connected, so `REDIS_URL` is empty.{{/dependencies.cache}}

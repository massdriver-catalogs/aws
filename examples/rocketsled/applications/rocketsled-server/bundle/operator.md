---
templating: mustache
---
# Rocketsled Server

**Open first:** https://console.aws.amazon.com/ecs/v2/clusters/{{dependencies.cluster.name}}/services/{{params.md_metadata.name_prefix}}/health?region={{dependencies.cluster.region}}

- **Image:** `{{params.image_uri}}`
- **Logs:** `/ecs/{{params.md_metadata.name_prefix}}`

## Tail the logs

```bash
aws logs tail /ecs/{{params.md_metadata.name_prefix}} --region {{dependencies.cluster.region}} --since 15m --follow
```

## Every action fails with 502

The Massdriver key is wrong or expired. Set the PaaS's `_MASSDRIVER_API_KEY` secret from `./deploy.sh env` and deploy.

## Everyone was signed out

The session secret changed. Each person's apps are still theirs only in the browser they made them in; a new sign-up starts empty.

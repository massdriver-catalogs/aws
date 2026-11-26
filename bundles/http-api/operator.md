---
templating: mustache
---
# HTTP API

{{#resources.api.endpoint}}
**URL:** {{resources.api.endpoint}}

{{/resources.api.endpoint}}
- **Region:** {{params.region}}
{{#resources.api}}
- **API ID:** `{{resources.api.id}}`
{{/resources.api}}
- **Limits:** {{params.throttle_rate}} requests per second, bursts of {{params.throttle_burst}}
- **CORS origins:** {{#params.cors_allowed_origins}}`{{.}}` {{/params.cors_allowed_origins}}{{^params.cors_allowed_origins}}none{{/params.cors_allowed_origins}}
- **Access log:** `/aws/apigateway/{{params.md_metadata.name_prefix}}`, days kept: {{params.access_log_retention_days}}

{{#resources.api}}
## Call it

```bash
curl -i {{resources.api.endpoint}}/
```

## 404 Not Found

No route matches. List what's attached:

```bash
aws apigatewayv2 get-routes --region {{params.region}} --api-id {{resources.api.id}} --query 'Items[].RouteKey'
```

Routes come from connected functions. Add the route to the function that should answer it, and redeploy that function.

## 429 Too Many Requests

The limit is working. If the traffic is real, raise **Steady requests per second** and **Burst requests**.

## 500, 502 or 503 from a route

The function failed or timed out. The access log has the reason:

```bash
aws logs tail /aws/apigateway/{{params.md_metadata.name_prefix}} --region {{params.region}} --since 15m --format short | grep -v '"status":"2'
```

`integrationError` names the problem. A timeout means the function ran past 30 seconds, which the API can't wait for. Then read the function's own logs (see its runbook).

## CORS errors in the browser

The page's origin must match one of **Browser origins allowed to call it** exactly, including scheme and port.

{{#resources.api.domain}}
## Custom domain doesn't answer

Check that the name resolves to API Gateway:

```bash
dig +short {{resources.api.domain}}
aws apigatewayv2 get-domain-name --region {{params.region}} --domain-name {{resources.api.domain}} \
  --query 'DomainNameConfigurations[0].[DomainNameStatus,TargetDomainName]'
```

- **`dig` returns nothing:** the zone isn't delegated yet. Its name servers must be set at the parent zone or registrar. Compare `dig NS <zone domain>` with the zone's name servers.
- **Status `PENDING_CERTIFICATE_REIMPORT` or a TLS error:** the zone's certificate expired or was replaced. Redeploy the DNS zone, then this API.
- **`404 Not Found` on every path:** the domain has no mapping to this API. Redeploy this API.

The AWS address still works while you fix it:

```bash
aws apigatewayv2 get-api --region {{params.region}} --api-id {{resources.api.id}} --query ApiEndpoint --output text
```
{{/resources.api.domain}}
{{/resources.api}}

## Deploy fails: certificate is in another region

The API and the DNS zone must be in the same region. Use a DNS zone from {{params.region}}, or clear **Subdomain** to deploy without a custom domain. Region can't change after the API is made.

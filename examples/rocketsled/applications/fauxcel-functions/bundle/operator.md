---
templating: mustache
---
# Fauxcel Functions

**URL:** {{dependencies.api.endpoint}}

- **Function and logs:** `{{params.md_metadata.name_prefix}}`, `/aws/lambda/{{params.md_metadata.name_prefix}}`
- **Memory and timeout:** {{params.memory_mb}} MB, {{params.timeout_seconds}} seconds
- **Image:** `{{params.image_uri}}`
- **KV:** {{#dependencies.kv}}`{{dependencies.kv.name}}`{{/dependencies.kv}}{{^dependencies.kv}}none{{/dependencies.kv}}
- **Blob:** {{#dependencies.blob}}`{{dependencies.blob.name}}`{{/dependencies.blob}}{{^dependencies.blob}}none{{/dependencies.blob}}

## Read the logs

```bash
aws logs tail /aws/lambda/{{params.md_metadata.name_prefix}} --region {{dependencies.api.region}} --since 15m --follow
```

## 500 or 503 from the endpoint

- **`Task timed out`:** raise **Timeout**. The endpoint gives up at 30 seconds.
- **`Runtime exited` or out of memory:** raise **Memory (MB)**. Server-rendered frameworks usually want 1024 or more.
- **`exec format error`:** the image isn't arm64.
- **Pages 404 but the function runs:** the framework's output wasn't copied into the image, or the Lambda Web Adapter's `AWS_LWA_PORT` doesn't match the port the server listens on.

## KV or Blob calls fail

`AccessDenied` means the store was connected after this function last deployed. Redeploy the functions.

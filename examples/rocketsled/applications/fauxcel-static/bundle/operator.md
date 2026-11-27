---
templating: mustache
---
# Fauxcel Static Site

**Open first:** {{dependencies.api.endpoint}}

- **Files:** `s3://{{dependencies.files.name}}/`
- **Function and logs:** `{{params.md_metadata.name_prefix}}`, `/aws/lambda/{{params.md_metadata.name_prefix}}`
- **Image:** `{{params.image_uri}}`

## A page is missing or old

```bash
aws s3 ls s3://{{dependencies.files.name}}/ --recursive | sort -k1,2 | tail -20
```

- **Not listed:** the upload missed it. Sync again from the build folder.
- **Listed but the browser shows the old one:** it's under `assets/` or `_next/static/`, which browsers keep for a year. Build tools rename those files on every change; a file there that keeps its name must move out of those folders.

## Every page is 404 or 500

```bash
aws logs tail /aws/lambda/{{params.md_metadata.name_prefix}} --region {{dependencies.api.region}} --since 15m
```

- **`KeyError: 'SITE_BUCKET'`:** the files bucket isn't connected. Connect it and redeploy.
- **`AccessDenied`:** the bucket was connected after the function last deployed. Redeploy.
- **The placeholder answers instead:** **Container image** is empty. Set it to the file server image in the template's image repository.

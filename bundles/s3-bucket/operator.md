---
templating: mustache
---
# S3 Bucket

{{#resources.bucket}}
- **Bucket:** `{{resources.bucket.name}}`, {{resources.bucket.region}}
{{/resources.bucket}}
- **Versioning:** {{#params.versioning}}on, days old versions are kept: {{params.noncurrent_version_expiration_days}}{{/params.versioning}}{{^params.versioning}}off{{/params.versioning}}
- **Encryption:** `{{params.encryption}}`
- **CORS origins:** {{#params.cors_allowed_origins}}`{{.}}` {{/params.cors_allowed_origins}}{{^params.cors_allowed_origins}}none{{/params.cors_allowed_origins}}

{{#resources.bucket}}
## Look at what's there

```bash
aws s3 ls s3://{{resources.bucket.name}}/ --region {{params.region}}
aws s3 ls s3://{{resources.bucket.name}}/ --region {{params.region}} --recursive --summarize | tail -2
```

## The app gets AccessDenied

1. **Is the policy attached?** The app's role needs **read** or **read-write**. Check who has each one:

   ```bash
{{#resources.bucket.policies}}
   aws iam list-entities-for-policy --policy-arn {{arn}} --query 'PolicyRoles[].RoleName'   # {{name}}
{{/resources.bucket.policies}}
   ```

   Writing with only **read** fails. Connect the app with the policy it needs, and redeploy the app.

2. **Is the request over plain HTTP?** The bucket refuses every request without TLS. Use an `https://` endpoint; the AWS SDKs do by default.

3. **Is it a public URL?** Nothing in this bucket can be made public, and ACLs such as `public-read` are rejected. Share a file with a presigned URL instead:

   ```bash
   aws s3 presign s3://{{resources.bucket.name}}/<key> --region {{params.region}} --expires-in 3600
   ```

4. **Is it from a browser?** A CORS error in the browser console means the site's origin isn't in **Browser upload origins**. Add it and redeploy. Check what the bucket allows now:

   ```bash
   aws s3api get-bucket-cors --bucket {{resources.bucket.name}} --region {{params.region}}
   ```

## Restore a deleted or overwritten file

{{#params.versioning}}
List the versions of the file. A delete leaves a delete marker on top of the old versions:

```bash
aws s3api list-object-versions --bucket {{resources.bucket.name}} --region {{params.region}} --prefix <key> \
  --query '{versions: Versions[].[VersionId,LastModified,IsLatest], deleteMarkers: DeleteMarkers[].[VersionId,LastModified,IsLatest]}'
```

- **The file was deleted:** remove the delete marker, and the newest old version is the current one again:

  ```bash
  aws s3api delete-object --bucket {{resources.bucket.name}} --region {{params.region}} --key <key> --version-id <delete-marker-version-id>
  ```

- **The file was overwritten:** copy the good version on top:

  ```bash
  aws s3api copy-object --bucket {{resources.bucket.name}} --region {{params.region}} --key <key> \
    --copy-source "{{resources.bucket.name}}/<key>?versionId=<good-version-id>"
  ```

Old versions are kept for {{params.noncurrent_version_expiration_days}} days after they are replaced.
{{/params.versioning}}
{{^params.versioning}}
Versioning is off, so deleted and overwritten files are gone. Turn on **Keep old versions** to protect files from here on.
{{/params.versioning}}

## The bill is growing

See how much is stored, including old versions:

```bash
aws cloudwatch get-metric-statistics --region {{params.region}} --namespace AWS/S3 --metric-name BucketSizeBytes \
  --dimensions Name=BucketName,Value={{resources.bucket.name}} Name=StorageType,Value=StandardStorage \
  --start-time $(date -u -v-2d +%FT%TZ 2>/dev/null || date -u -d '-2 days' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
  --period 86400 --statistics Average
```

- Old versions are often most of it. Lower **Delete old versions after** and redeploy.
- For temporary data, set **Delete files after**.

## Decommission fails with BucketNotEmpty

The bucket still holds files or old versions. Copy out anything you need, then empty it:

```bash
aws s3 rm s3://{{resources.bucket.name}}/ --region {{params.region}} --recursive
aws s3api list-object-versions --bucket {{resources.bucket.name}} --region {{params.region}} \
  --query '{Objects: [Versions, DeleteMarkers][][].{Key: Key, VersionId: VersionId}}' --no-paginate > /tmp/versions.json
aws s3api delete-objects --bucket {{resources.bucket.name}} --region {{params.region}} --delete file:///tmp/versions.json
```

Repeat the last two commands until the list is empty, then decommission again.
{{/resources.bucket}}

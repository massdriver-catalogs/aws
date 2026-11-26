---
templating: mustache
---
# DynamoDB Table

{{#resources.table}}
- **Table:** `{{resources.table.name}}`, {{resources.table.region}}
{{/resources.table}}
- **Keys:** `{{params.partition_key.name}}` ({{params.partition_key.type}}){{#params.sort_key.name}}, sort key `{{params.sort_key.name}}` ({{params.sort_key.type}}){{/params.sort_key.name}}
{{#params.ttl_attribute}}
- **Expires items by:** `{{params.ttl_attribute}}`
{{/params.ttl_attribute}}
- **Point-in-time recovery:** {{#params.point_in_time_recovery}}on{{/params.point_in_time_recovery}}{{^params.point_in_time_recovery}}off{{/params.point_in_time_recovery}}
- **Deletion protection:** {{#params.deletion_protection}}on{{/params.deletion_protection}}{{^params.deletion_protection}}off{{/params.deletion_protection}}

{{#resources.table}}
## Look at the data

```bash
aws dynamodb describe-table --region {{params.region}} --table-name {{resources.table.name}} \
  --query 'Table.[TableStatus,ItemCount,TableSizeBytes]'
aws dynamodb scan --region {{params.region}} --table-name {{resources.table.name}} --max-items 10
```

`ItemCount` and size are refreshed by DynamoDB about every six hours.

## The app gets AccessDeniedException

The app's role doesn't have one of this table's policies, or has **read** and is writing. Check who has each one:

```bash
{{#resources.table.policies}}
aws iam list-entities-for-policy --policy-arn {{arn}} --query 'PolicyRoles[].RoleName'   # {{name}}
{{/resources.table.policies}}
```

Connect the app to this table with the policy it needs, and redeploy the app.

## Requests are throttled

The app sees `ProvisionedThroughputExceededException` or `ThrottlingException`.

1. See how many requests were throttled in the last hour:

   ```bash
   aws cloudwatch get-metric-statistics --region {{params.region}} --namespace AWS/DynamoDB \
     --metric-name ThrottledRequests --dimensions Name=TableName,Value={{resources.table.name}} Name=Operation,Value=PutItem \
     --start-time $(date -u -v-1H +%FT%TZ 2>/dev/null || date -u -d '-1 hour' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
     --period 300 --statistics Sum
   ```

   Change `PutItem` to `GetItem`, `Query` or `UpdateItem` for other operations.

2. Find the hot keys. Turn on Contributor Insights, wait a few minutes, then list the most used keys:

   ```bash
   aws dynamodb update-contributor-insights --region {{params.region}} --table-name {{resources.table.name}} --contributor-insights-action ENABLE
   aws dynamodb describe-contributor-insights --region {{params.region}} --table-name {{resources.table.name}}
   ```

   Open **CloudWatch → Contributor Insights** to see the top partition keys. Turn it off when you are done; it costs per rule.

3. Fix:
   - **One key gets most of the traffic:** a single partition takes about 1,000 writes and 3,000 reads per second. Spread writes over more key values, for example by adding a suffix like `#0`–`#9` and reading all of them.
   - **Traffic jumped suddenly:** on-demand tables absorb about double the previous peak at once. Retry with backoff (the AWS SDKs do this by default); the table adapts within minutes.

## Restore deleted or broken data

{{#params.point_in_time_recovery}}
Find the window you can restore from:

```bash
aws dynamodb describe-continuous-backups --region {{params.region}} --table-name {{resources.table.name}} \
  --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription'
```

Restore to a new table, at a moment before the damage:

```bash
aws dynamodb restore-table-to-point-in-time --region {{params.region}} \
  --source-table-name {{resources.table.name}} --target-table-name {{resources.table.name}}-restored \
  --restore-date-time <YYYY-MM-DDTHH:MM:SSZ>
aws dynamodb wait table-exists --region {{params.region}} --table-name {{resources.table.name}}-restored
```

The restore can take an hour or more for large tables. Copy the items you need back into `{{resources.table.name}}`, then delete the restored table:

```bash
aws dynamodb delete-table --region {{params.region}} --table-name {{resources.table.name}}-restored
```
{{/params.point_in_time_recovery}}
{{^params.point_in_time_recovery}}
Point-in-time recovery is off, so there is nothing to restore from. Turn it on to protect data from here on.
{{/params.point_in_time_recovery}}

## Decommission fails

**Deletion protection** is on. Turn it off, deploy, then decommission.
{{/resources.table}}

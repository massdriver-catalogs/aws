---
templating: mustache
---
# Valkey Cache

{{#resources.cache}}
## Connect from an ECS task

The cache only accepts connections from the client security group, so connect from a task that has it. Open a shell in a running task with ECS Exec:

```bash
aws ecs execute-command --region {{resources.cache.region}} --cluster <cluster> --task <task-id> \
  --container <container> --interactive --command "/bin/sh"
```

Then, inside the task:

```bash
redis-cli -h {{resources.cache.hostname}} -p {{resources.cache.port}} --tls PING
redis-cli -h {{resources.cache.hostname}} -p {{resources.cache.port}} --tls INFO keyspace
```

`valkey-cli` takes the same flags. If the image has neither, `openssl` works; type `PING` and press Enter:

```bash
openssl s_client -connect {{resources.cache.hostname}}:{{resources.cache.port}} -quiet
```

## The app can't connect

- **Timeout:** the app is missing the client security group, or runs in another VPC. Check that its tasks or function have `{{resources.cache.client_security_group_id}}`:

  ```bash
  aws ec2 describe-network-interfaces --region {{resources.cache.region}} \
    --filters Name=group-id,Values={{resources.cache.client_security_group_id}} \
    --query 'NetworkInterfaces[].[Description,PrivateIpAddress]' --output table
  ```

  An empty list means nothing has the group. Connect the app to this cache and redeploy it.

- **Connection reset or closed right away:** the client isn't using TLS. Use a `rediss://` URL or the client's TLS option.

- **`MOVED` or `CROSSSLOT` errors:** the cache is clustered. Turn on the client's cluster mode, and keep keys used in one command or transaction in the same hash slot with a `{tag}`, for example `{user:42}:cart` and `{user:42}:profile`.

## Keys are disappearing (evictions)

See how full the cache is and whether it is evicting:

```bash
for m in BytesUsedForCache Evictions; do
  aws cloudwatch get-metric-statistics --region {{resources.cache.region}} --namespace AWS/ElastiCache \
    --metric-name $m --dimensions Name=clusterId,Value={{resources.cache.name}} \
    --start-time $(date -u -v-3H +%FT%TZ 2>/dev/null || date -u -d '-3 hours' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
    --period 300 --statistics Maximum --query "Datapoints[].[Timestamp,Maximum]" --output text | sort | tail -3
done
```

- **`BytesUsedForCache` is at the {{params.max_data_storage_gb}} GB limit:** raise **Data storage limit** and redeploy, or set shorter expiry times on keys.
- **Writes fail with `OOM command not allowed`:** the cache is full and the keys have no expiry, so nothing can be evicted. Set expiry times, or raise the limit.
- **No evictions, but keys are gone:** they expired. Check the TTLs the app sets: `redis-cli ... --tls TTL <key>`.

## Requests are slow or throttled

```bash
for m in ElastiCacheProcessingUnits ThrottledCmds; do
  aws cloudwatch get-metric-statistics --region {{resources.cache.region}} --namespace AWS/ElastiCache \
    --metric-name $m --dimensions Name=clusterId,Value={{resources.cache.name}} \
    --start-time $(date -u -v-1H +%FT%TZ 2>/dev/null || date -u -d '-1 hour' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
    --period 60 --statistics Sum --query "Datapoints[].[Timestamp,Sum]" --output text | sort | tail -5
done
```

`ElastiCacheProcessingUnits` near {{params.max_ecpu_per_second}} per second, or any `ThrottledCmds`, means the request limit is reached. Raise **Request limit** and redeploy. Before that, look for expensive commands: `KEYS *`, large `HGETALL` or `SMEMBERS`, and big values each cost many ECPUs. Find them with:

```bash
redis-cli -h {{resources.cache.hostname}} -p {{resources.cache.port}} --tls --bigkeys
```

## Too many connections

A serverless cache takes up to 65,000 connections. Check how many are open:

```bash
aws cloudwatch get-metric-statistics --region {{resources.cache.region}} --namespace AWS/ElastiCache \
  --metric-name CurrConnections --dimensions Name=clusterId,Value={{resources.cache.name}} \
  --start-time $(date -u -v-1H +%FT%TZ 2>/dev/null || date -u -d '-1 hour' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
  --period 60 --statistics Maximum --query "Datapoints[].[Timestamp,Maximum]" --output text | sort | tail -5
```

A count that keeps climbing is a connection leak: the app opens a client per request instead of reusing one. In Lambda, create the client outside the handler so warm invocations reuse it.

## Take a snapshot before a risky change

{{#params.snapshot_retention_days}}
Daily snapshots are kept for {{params.snapshot_retention_days}} days. Take one by hand before a large data migration:
{{/params.snapshot_retention_days}}
{{^params.snapshot_retention_days}}
Daily snapshots are off. Take one by hand before a large data migration:
{{/params.snapshot_retention_days}}

```bash
aws elasticache create-serverless-cache-snapshot --region {{resources.cache.region}} \
  --serverless-cache-name {{resources.cache.name}} --serverless-cache-snapshot-name {{resources.cache.name}}-$(date -u +%Y%m%d%H%M)
aws elasticache describe-serverless-cache-snapshots --region {{resources.cache.region}} --serverless-cache-name {{resources.cache.name}}
```

A snapshot restores only into a new cache, not into this one. Most apps refill the cache from their database instead.
{{/resources.cache}}

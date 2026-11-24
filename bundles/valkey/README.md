# Valkey Cache

A serverless Valkey cache for one app. Valkey is an open-source fork of Redis, and Redis clients and commands work with it. Use it for sessions, rate limits, short-lived results and anything else that must be fast but can be rebuilt.

## What it needs

- An AWS account to deploy into.
- A VPC with internal or private subnets in at least two availability zones. Internal subnets are used if there are any. The cache is created in the VPC's region.

## What it makes

- The cache. It grows and shrinks with use; there are no nodes to size. It is billed for the data stored and the requests served, up to the two limits you set.
- Two security groups. The cache's own group allows connections only from the **client** group. Attach the client group to anything that connects, such as an ECS service or Lambda function.
- Alarms when data or requests pass 80% of their limits.

## Connecting

Connections must use TLS. Most Redis clients turn it on with a `rediss://` URL or a `tls` option:

```
rediss://<hostname>:6379
```

Use the hostname on port 6379 for reads and writes. The reader hostname on port 6380 spreads reads across replicas, which may lag slightly behind. There is no password; only members of the client security group can connect.

## Limits

- **Data storage limit:** when the cache is full, it evicts the least recently used keys that have an expiry set. If none can be evicted, writes fail with an out-of-memory error.
- **Request limit:** requests above it are throttled and wait or fail. Simple reads and writes of small values use about one ECPU each; large values and complex commands use more.

Set expiry times on keys so old data leaves on its own.

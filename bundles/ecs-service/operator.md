---
templating: mustache
---
# ECS Service

## Ship your app

### 1. Add a Dockerfile

Any web server works if it listens on `PORT` (set to **Container port**, now {{params.port}}) and answers **Health check path** (now `{{params.health_check_path}}`) with 2xx. A small Node example:

```js
// server.js
const http = require("http");
http
  .createServer((req, res) => {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true, path: req.url }));
  })
  .listen(process.env.PORT || 8080);
```

```dockerfile
# Dockerfile
FROM node:22-alpine
WORKDIR /app
COPY server.js .
USER node
CMD ["node", "server.js"]
```

### 2. Build and push

The service runs **{{params.architecture}}** tasks. Build with `--platform linux/arm64` for arm64, or `--platform linux/amd64` for x86_64. A mismatch fails with `exec format error`.

{{#dependencies.codebase}}
```bash
REPO={{dependencies.codebase.registry.url}}
TAG=$(git rev-parse --short HEAD)
aws ecr get-login-password --region {{dependencies.codebase.registry.region}} \
  | docker login --username AWS --password-stdin {{dependencies.codebase.registry.registry_id}}.dkr.ecr.{{dependencies.codebase.registry.region}}.amazonaws.com
docker buildx build --platform linux/arm64 -t $REPO:$TAG --push .
```
{{/dependencies.codebase}}
{{^dependencies.codebase}}
No codebase is connected, so the service can't pull from ECR. Connect the project's codebase and deploy, then push to its repository:

```bash
REPO=<account>.dkr.ecr.{{dependencies.cluster.region}}.amazonaws.com/<repository>
TAG=$(git rev-parse --short HEAD)
docker buildx build --platform linux/arm64 -t $REPO:$TAG --push .
```
{{/dependencies.codebase}}

### 3. Deploy it

```bash
mass instance deploy {{id}} --patch ".image = \"$REPO:$TAG\"" --patch '.port = 8080' -m "Ship $TAG" --follow
```

The deploy waits until the new tasks are healthy. If they keep failing, it rolls back and fails; see "Deployment rolled back" below.

### 4. Give it an address

{{#dependencies.dns}}
```bash
mass instance deploy {{id}} --patch '.subdomain = "api"' -m "Serve at api.{{dependencies.dns.domain}}" --follow
curl -i https://api.{{dependencies.dns.domain}}/
```

A new DNS name can take a minute to resolve. If the cluster has no DNS zone, the load balancer only serves HTTP; use `http://`.
{{/dependencies.dns}}
{{^dependencies.dns}}
Connect a DNS zone to this service, then set **Subdomain**:

```bash
mass instance deploy {{id}} --patch '.subdomain = "api"' -m "Give it an address" --follow
```
{{/dependencies.dns}}

### 5. Connect a database

Connect a PostgreSQL or MariaDB database to this service on the canvas and deploy. The service joins the database's security group and gets:

- PostgreSQL: `PGHOST` `PGPORT` `PGDATABASE` `PGUSER` `PGPASSWORD`
- MariaDB: `MYSQL_HOST` `MYSQL_PORT` `MYSQL_DATABASE` `MYSQL_USER` `MYSQL_PASSWORD`

The password comes from Secrets Manager when the task starts. There is no `DATABASE_URL`; build one in code if your library needs it. The Node `pg` client reads the `PG*` variables on its own:

```js
const { Client } = require("pg");
const db = new Client(); // PGHOST, PGUSER, PGPASSWORD, ... from the environment
await db.connect();
```

```js
// MariaDB with mysql2
const mysql = require("mysql2/promise");
const db = await mysql.createConnection({
  host: process.env.MYSQL_HOST, port: process.env.MYSQL_PORT, database: process.env.MYSQL_DATABASE,
  user: process.env.MYSQL_USER, password: process.env.MYSQL_PASSWORD,
});
```

A cache sets `REDIS_URL` (TLS, `rediss://`); a table `TABLE_NAME`; a bucket `BUCKET_NAME`; a queue `QUEUE_URL`. AWS SDKs pick up the task's role on their own; no keys needed.

### 6. Scale

```bash
# Bigger tasks
mass instance deploy {{id}} --patch '.size = "1024/2048"' -m "1 vCPU, 2 GB" --follow
# At least 2 tasks, up to 6 when CPU is above 60%
mass instance deploy {{id}} --patch '.desired_count = 2' --patch '.max_count = 6' --patch '.cpu_target = 60' -m "Autoscale 2-6" --follow
```

## Read the logs

```bash
aws logs tail /ecs/{{id}} --region {{dependencies.cluster.region}} --since 15m --follow
```

## Deployment rolled back

The circuit breaker stopped the deploy because new tasks kept failing, and the service went back to the last working task definition. Find out why the tasks stopped:

```bash
aws ecs describe-services --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} --services {{id}} \
  --query 'services[0].events[:10].[createdAt,message]' --output text

aws ecs describe-tasks --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} \
  --tasks $(aws ecs list-tasks --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} --service-name {{id}} --desired-status STOPPED --query 'taskArns[:5]' --output text) \
  --query 'tasks[].[stoppedAt,stoppedReason,containers[0].exitCode,containers[0].reason]' --output text
```

- **`Essential container in task exited`** with an exit code: the app crashed on start. The cause is in the logs, above.
- **`exec format error`** in the logs: the image is built for the wrong CPU. Rebuild for **{{params.architecture}}**.
- **`Task failed ELB health checks`:** the app started but didn't answer the health check. See the next section.
- **`CannotPullContainerError`:** see "Can't pull the image".
- **`ResourceInitializationError: unable to pull secrets`:** the task can't read a database secret. Check the database is still connected and the VPC has egress.
- **`OutOfMemoryError`** or exit code 137: raise **Task size**.

## Unhealthy targets

```bash
TG=$(aws ecs describe-services --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} --services {{id}} \
  --query 'services[0].loadBalancers[0].targetGroupArn' --output text)
aws elbv2 describe-target-health --region {{dependencies.cluster.region}} --target-group-arn $TG \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason,TargetHealth.Description]' --output text
```

- **`Target.Timeout`:** nothing answers on port {{params.port}}. The app listens on a different port, or only on `127.0.0.1`. Listen on `0.0.0.0` and `PORT`.
- **`Target.ResponseCodeMismatch`:** `{{params.health_check_path}}` returns 4xx or 5xx. Make it return 200 without a login or a database call that can fail.
- **`Target.FailedHealthChecks` right after start:** the app takes longer than 60 seconds to boot. Make startup faster.

## Can't pull the image

`CannotPullContainerError` in the stopped reason:

- **`not found` / `manifest unknown`:** the tag isn't in the repository. List what's there:
{{#dependencies.codebase}}

  ```bash
  aws ecr describe-images --region {{dependencies.codebase.registry.region}} --repository-name {{dependencies.codebase.registry.name}} \
    --query 'sort_by(imageDetails,&imagePushedAt)[-5:].imageTags' --output text
  ```
{{/dependencies.codebase}}
- **`AccessDeniedException` / `403`:** the image is in an ECR repository this service has no pull policy for. Connect the codebase that owns it and deploy.
- **`i/o timeout` / `dial tcp`:** the private subnets can't reach the registry. The VPC needs internet egress, or VPC endpoints for ECR and S3.
- **`toomanyrequests`:** Docker Hub rate limit. Push the image to ECR instead.
- **`image Manifest does not contain descriptor matching platform`:** the image has no **{{params.architecture}}** build. Rebuild with the right `--platform`.

## Open a shell in a task

Needs the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) on your machine.

```bash
TASK=$(aws ecs list-tasks --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} --service-name {{id}} --query 'taskArns[0]' --output text)
aws ecs execute-command --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} \
  --task $TASK --container app --interactive --command "/bin/sh"
```

- **`TargetNotConnectedException`:** the task started before ECS Exec could reach SSM. It needs internet egress (or SSM endpoints). Check the agent:

  ```bash
  aws ecs describe-tasks --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} --tasks $TASK \
    --query 'tasks[0].containers[0].managedAgents'
  ```

- **`/bin/sh` not found:** the image has no shell (distroless). Use a debug image tag.

## 503 from the load balancer

{{#params.subdomain}}
A 503 means the rule for `{{params.subdomain}}` matched but no task is healthy. Check the count and the targets:

```bash
aws ecs describe-services --region {{dependencies.cluster.region}} --cluster {{dependencies.cluster.name}} --services {{id}} \
  --query 'services[0].[desiredCount,runningCount,pendingCount]'
```

- **Running is 0:** tasks keep stopping. See "Deployment rolled back".
- **Running but 503:** the targets are unhealthy. See "Unhealthy targets".
{{/params.subdomain}}
{{^params.subdomain}}
This service has no **Subdomain**, so the load balancer never sends it traffic. A 503 on another name belongs to that service.
{{/params.subdomain}}

A 404 instead means no rule matched the name: the subdomain is different, or the cluster gained a DNS zone after this service deployed. Redeploy the service.

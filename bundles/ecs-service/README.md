# ECS Service

A containerized app on Fargate, in a shared ECS cluster. It runs in the private subnets of the cluster's VPC and, with a **Subdomain**, answers at `https://<subdomain>.<the cluster's DNS zone>` through the cluster's load balancer. Without a subdomain it is a worker: no address, just tasks.

## What it needs

- **An ECS cluster.** The service uses the cluster's VPC and DNS zone, so it can't end up in a different network than the load balancer. A subdomain needs a cluster with a DNS zone.
- **A codebase** (optional) lets tasks pull images from its ECR repository.

## Alarms

Alarms fire when CPU or memory averages over 80% for 15 minutes. With a subdomain, they also fire when a task fails its health check, when more than 5% of requests return 5xx, and when 5% of requests are slower than **Alarm when responses are slower than**.

## Before your app exists

Leave **Container image** empty and the service runs `public.ecr.aws/nginx/nginx:stable-alpine` on port 80. It answers 200, so the address, the DNS record and the load balancer work from the first deploy. Pulling it needs internet egress on the cluster's VPC.

## Environment variables

`PORT` is always set to the container port. Add plain configuration in **Environment variables**.

## Deploys

A deploy starts new tasks, waits for them to pass the health check, then stops the old ones. If the new tasks keep failing, the deploy rolls back to the last working version and the deploy fails.

## Scaling

**Tasks** always run. Above that, up to **Most tasks when busy**, a task is added when average CPU passes **CPU target** and removed when it falls.

## Debugging

ECS Exec is on, so you can open a shell in a running task. See the operator guide.

## Running an app on it

This bundle is a runtime. An app's own bundle sets `app.runtime: ecs-service`, declares the databases, caches, tables, buckets and queues it uses, and maps their fields to environment variables. Massdriver builds the two into one bundle when the app is published.

The service gets access to the standard types the app connects. It joins the client security group of a PostgreSQL, MariaDB or Valkey. A database's policies let ECS read its password when a task starts; the app itself can't read the secret. The task's role, which the app's AWS SDK uses, gets read-write access to a DynamoDB table or S3 bucket, and can send to and consume from an SQS queue. Other types reach the app only through its environment variables. A variable that points at a Secrets Manager value, such as `.dependencies.db.secret_arn + ":password::"`, is read by ECS when a task starts and never written into the task definition.

```yaml
dependencies:
  db:
    resource_type: aws-postgres@0.0.0
    required: true
app:
  runtime: ecs-service
  envs:
    PGHOST: .dependencies.db.hostname
    PGPASSWORD: '.dependencies.db.secret_arn + ":password::"'
```

See [examples/telehealth](../../examples/telehealth/) for three apps built this way.

# ECS Service

A containerized app on Fargate, in a shared ECS cluster. It runs in the VPC's private subnets and, with a **Subdomain**, answers at `https://<subdomain>.<DNS zone>` through the cluster's load balancer. Without a subdomain it is a worker: no address, just tasks.

## What it needs

- **An ECS cluster** and **the VPC** it is in. The VPC needs private subnets.
- **A DNS zone** for a subdomain. A subdomain without a zone fails the deploy.
- **A codebase** (optional) lets tasks pull images from its ECR repository.

## Before your app exists

Leave **Container image** empty and the service runs `public.ecr.aws/nginx/nginx:stable-alpine` on port 80. It answers 200, so the address, the DNS record and the load balancer work from the first deploy. Pulling it needs internet egress on the VPC.

## Connected resources

Connect a resource and the service gets the access and the environment variables for it:

| Connect | Variables | Access |
|---|---|---|
| PostgreSQL | `PGHOST` `PGPORT` `PGDATABASE` `PGUSER` `PGPASSWORD` | The database's client security group; the password comes from Secrets Manager |
| MariaDB | `MYSQL_HOST` `MYSQL_PORT` `MYSQL_DATABASE` `MYSQL_USER` `MYSQL_PASSWORD` | Same as PostgreSQL |
| Valkey cache | `REDIS_URL` (`rediss://host:port`) | The cache's client security group |
| DynamoDB table | `TABLE_NAME` | **Table access**, or all of the table's policies |
| S3 bucket | `BUCKET_NAME` | **Bucket access**, or all of the bucket's policies |
| SQS queue | `QUEUE_URL` | **Queue access**, or all of the queue's policies |

`PORT` is always set to the container port.

Passwords are never written into the task definition. ECS reads them from Secrets Manager when a task starts. For the same reason there is no `DATABASE_URL` or `MYSQL_URL`: build one in your app from the variables above if your library needs it. Most PostgreSQL clients read the `PG*` variables on their own.

## Deploys

A deploy starts new tasks, waits for them to pass the health check, then stops the old ones. If the new tasks keep failing, the deploy rolls back to the last working version and the deploy fails.

## Scaling

**Tasks** always run. Above that, up to **Most tasks when busy**, a task is added when average CPU passes **CPU target** and removed when it falls.

## Debugging

ECS Exec is on, so you can open a shell in a running task. See the operator guide.

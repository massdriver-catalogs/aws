# Lambda Function

A function on arm64 that answers routes on a connected HTTP API. Connect a database, a cache, a DynamoDB table, an S3 bucket or an SQS queue, and the function gets the settings and the access it needs to use them.

## What it needs

- An AWS role to deploy with.
- An **HTTP API**. The function runs in the API's region, and every connected resource must be in that region too.
- Optional: the **codebase**, for the ECR repository your images go to. The function gets permission to pull from it.
- Optional: the **VPC**. It's required when a PostgreSQL or MariaDB database or a Valkey cache is connected, because they only listen inside the VPC.

## What it makes

- The function, its IAM role, and a log group.
- An API route for each entry in **Routes**.
- An alarm when the function throws errors or times out more than 5 times in 5 minutes.

## Code

Leave **Container image** empty and a built-in placeholder answers every route. It echoes the request and checks each connected resource, so you can see the API, the function and the network work before any real code exists.

To run your own code, push an **arm64** image to the codebase's ECR repository and set its address. The image must speak the Lambda runtime API: start from an AWS base image (`public.ecr.aws/lambda/python`, `nodejs`, …), or add the [Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter) to an ordinary web server image. Use a new tag or a digest for every release.

## Routes

Each entry is `METHOD /path`. `ANY /{proxy+}` plus `ANY /` sends everything to this function. To split an API across functions, give each one its own routes, such as `GET /items` and `POST /items/{id}`.

The function receives API Gateway's version 2.0 event and returns `statusCode`, `headers` and `body`.

## Connected resources

Each connected resource sets environment variables. The names are the same in the ECS service bundle, so an app can move between them without changes.

| Connected | Environment variables | Access |
|---|---|---|
| PostgreSQL | `DATABASE_URL` (`postgres://user:password@host:port/db`), `PGHOST`, `PGPORT`, `PGDATABASE`, `PGUSER`, `PGPASSWORD` | Network access, and the database's policies |
| MariaDB | `MYSQL_URL` (`mysql://user:password@host:port/db`), `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_DATABASE`, `MYSQL_USER`, `MYSQL_PASSWORD` | Network access, and the database's policies |
| Valkey cache | `REDIS_URL` (`rediss://host:port`, TLS) | Network access |
| DynamoDB table | `TABLE_NAME` | **Table access** policy, read-write by default |
| S3 bucket | `BUCKET_NAME` | **Bucket access** policy, read-write by default |
| SQS queue | `QUEUE_URL` | **Queue access** policy, send by default |

You can't set these names yourself in **Environment variables**; the deploy fails if you try.

The password in `DATABASE_URL` and `MYSQL_URL` is URL-encoded, so special characters are safe.

## Network

With a database or cache connected, the function runs in the VPC's private subnets and joins each one's client security group, which is what lets it connect. Without one, it stays outside the VPC.

Inside the VPC, the function reaches AWS services such as DynamoDB, S3 and SQS through the VPC's internet egress. If the VPC has no egress, those calls time out unless the VPC has endpoints for them.

## Queue

Set **Queue access** to `consume` and turn on **Consume from the queue**, and Lambda reads the queue and calls the function with up to 10 messages at a time. If the function returns without an error, the messages are deleted; if it fails, they come back after the queue's visibility timeout and, after enough tries, go to the dead-letter queue.

The same function still answers its API routes. Tell the two apart by the event: queue events have a `Records` list.

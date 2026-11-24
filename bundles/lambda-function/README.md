# Lambda Function

A function on arm64 that answers routes on a connected HTTP API.

## What it needs

- An AWS role to deploy with.
- An **HTTP API**. The function runs in the API's region, and every connected resource must be in that region too.
- Optional: the **codebase**, for where your images go. The function gets permission to pull from its ECR repository.
- Optional: the **VPC**. It's required when the app connects a PostgreSQL or MariaDB database or a Valkey cache, because they only listen inside the VPC.

## What it makes

- The function, its IAM role, and a log group.
- An API route for each entry in **Routes**.
- Alarms when the function throws errors or times out more than 5 times in 5 minutes, is throttled, or takes over 80% of its timeout.

## Code

Leave **Container image** empty and a built-in placeholder answers every route. It echoes the request, so you can see the API, the function and the network work before any real code exists.

To run your own code, push an **arm64** image to the codebase's ECR repository and set its address. The image must speak the Lambda runtime API: start from an AWS base image (`public.ecr.aws/lambda/python`, `nodejs`, …), or add the [Lambda Web Adapter](https://github.com/awslabs/aws-lambda-web-adapter) to an ordinary web server image. Use a new tag or a digest for every release.

## Routes

Each entry is `METHOD /path`. `ANY /{proxy+}` plus `ANY /` sends everything to this function. To split an API across functions, give each one its own routes, such as `GET /items` and `POST /items/{id}`.

The function receives API Gateway's version 2.0 event and returns `statusCode`, `headers` and `body`.

## Network

When the app connects a database or cache, the function runs in the VPC's private subnets and joins each one's client security group, which is what lets it connect. Without one, it stays outside the VPC.

Inside the VPC, the function reaches S3 and DynamoDB through the VPC's gateway endpoints. Other AWS services, such as SQS, go through the VPC's internet egress; with no egress, those calls time out unless the VPC has an interface endpoint for them.

## Queue

Turn on **Consume from the queue** and Lambda reads the app's SQS queue and calls the function with up to 10 messages at a time. If the function returns without an error, the messages are deleted; if it fails, they come back after the queue's visibility timeout and, after enough tries, go to the dead-letter queue. To fail only some of a batch, return their message IDs as `{"batchItemFailures": [{"itemIdentifier": "<messageId>"}]}`; the rest are deleted.

The same function still answers its API routes. Tell the two apart by the event: queue events have a `Records` list.

## Running an app on it

This bundle is a runtime. An app's own bundle sets `app.runtime: lambda-function`, declares the databases, caches, tables, buckets and queues it uses, and maps their fields to environment variables. Massdriver builds the two into one bundle when the app is published. The function joins the client security group of a PostgreSQL, MariaDB or Valkey, gets read-write access to a DynamoDB table or S3 bucket, and can send to and consume from an SQS queue. Other types reach the app only through its environment variables. Lambda has no way to hide a value, so an app that declares secrets, or a database password, gets it as a plain environment variable; an app with `app.secrets` fails to deploy here and belongs on ecs-service. See [examples/telehealth](../../examples/telehealth/) for three apps built this way.

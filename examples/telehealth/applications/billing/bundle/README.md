# Tendwell Billing

Turns closed encounters into insurance claims. It came with the Clearpath acquisition and runs on MySQL-compatible MariaDB. It pulls closed encounters from the Care API, prices them, stores each claim, and writes a claim file to S3 for the clearinghouse.

Runs on the catalog's `ecs-service` runtime: the runtime decides the Fargate service, its load balancer rule, IAM and logs, and this bundle adds the app's contract.

## Needs

- The Care API (`tendwell-care-api`), from the Care project in the same environment.
- MariaDB (`aws-mariadb`) for claims.
- An S3 bucket (`aws-s3-bucket`) for claim files.
- An ECR repository (`aws-ecr-repository`) holding the app image.
- The environment's ECS cluster, VPC and DNS zone, as environment defaults.

## Makes

A `tendwell-billing-api` resource with the service's URL.

## Routes

| Route | Does |
|---|---|
| `GET /` | Claim count and total billed |
| `POST /claims/run` | File claims for encounters closed since the last run |
| `GET /claims` | The latest claims |
| `GET /health` | Health check |

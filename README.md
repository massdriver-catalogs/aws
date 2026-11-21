# Massdriver for AWS

Ship apps on AWS with Massdriver. This catalog has the network and DNS for each environment, two ways to run code (Lambda behind API Gateway, or containers on ECS Fargate), the data stores apps usually need, and the pieces that onboard a new app: its GitHub repository, its image registry and its Massdriver project.

## What's in it

### Environment

Deploy these once per environment (`dev`, `staging`, `prod`) and set each as an environment default. Everything else in the environment finds them on its own.

| Bundle | Makes | Resource type |
|---|---|---|
| `vpc` | A VPC with public, private and internal subnets, and a choice of internet egress | `aws-vpc` |
| `dns-zone` | A Route 53 zone, such as `dev.example.com`, and a certificate for every name under it | `aws-dns-zone` |
| `ecs-cluster` | A Fargate cluster and the load balancer its services share | `aws-ecs-cluster` |
| `github-actions-oidc` | The AWS account's trust in GitHub Actions. Once per account | `aws-github-oidc` |

### Runtimes

| Bundle | Makes | Resource type |
|---|---|---|
| `http-api` | An API Gateway HTTP API, optionally at `<subdomain>.<zone>` | `aws-http-api` |
| `lambda-function` | A function that answers routes on an HTTP API, or reads a queue | — |
| `ecs-service` | A container service on Fargate, at `<subdomain>.<zone>` or as a worker with no address | — |

### Data stores

| Bundle | Makes | Resource type |
|---|---|---|
| `postgres` | RDS for PostgreSQL | `aws-postgres` |
| `mariadb` | RDS for MariaDB | `aws-mariadb` |
| `dynamodb-table` | A DynamoDB table, billed per request | `aws-dynamodb-table` |
| `s3-bucket` | A private S3 bucket | `aws-s3-bucket` |
| `valkey` | A serverless Valkey (Redis-compatible) cache | `aws-valkey` |
| `sqs-queue` | An SQS queue with a dead-letter queue | `aws-sqs-queue` |

### App onboarding

| Bundle | Makes | Resource type |
|---|---|---|
| `ecr-repository` | The app's image repository, with push and pull policies | `aws-ecr-repository` |
| `github-repo` | The app's GitHub repository, with a pipeline that builds, pushes and deploys | `source-repository` |
| `massdriver-project` | The app's Massdriver project, its environments, and a group its pipeline deploys with | `app-project` |
| `codebase` | The repository and registry as one resource, shared with the app's project | `aws-codebase` |

### Credentials

| Credential | Used by |
|---|---|
| AWS IAM Role (`aws-iam-role`) | Every AWS bundle |
| GitHub App (`github-app`) | `github-repo` |
| Massdriver Service Account (`massdriver-service-account`) | `massdriver-project`, `github-repo`, `codebase` |

## How it fits together

```mermaid
flowchart TB
  subgraph env[Each environment]
    vpc[vpc]
    dns[dns-zone]
    cluster[ecs-cluster]
  end
  subgraph app[An app's project]
    api[http-api] --> fn[lambda-function]
    svc[ecs-service]
    pg[(postgres)] --> fn
    pg --> svc
    q[sqs-queue] --> fn
  end
  vpc -. default .-> app
  dns -. default .-> app
  cluster -. default .-> app
  cb[codebase] -. default .-> app
```

Dotted lines are environment defaults; solid lines are links on the app's canvas.

- **Subdomains.** The DNS zone's certificate covers every name one level under it. An `http-api` or `ecs-service` with **Subdomain** `api` answers at `https://api.dev.example.com`, with the record and certificate handled for you. The zone, the API and the cluster must be in the same region.
- **Databases and caches** sit in the VPC's internal subnets and only accept connections from their own client security group. A runtime joins that group when you link the store to it.
- **Policies.** Tables, buckets, queues and registries publish IAM policies such as `read`, `read-write`, `send` or `pull`. A runtime attaches the one you pick (`ecs-service` attaches all of them if you don't pick); nothing writes its own IAM for a store.

### Environment variables

Link a data store to a runtime and the runtime gets the same variables on Lambda and ECS:

| Store | Variables |
|---|---|
| PostgreSQL | `PGHOST` `PGPORT` `PGDATABASE` `PGUSER` `PGPASSWORD`, plus `DATABASE_URL` on Lambda |
| MariaDB | `MYSQL_HOST` `MYSQL_PORT` `MYSQL_DATABASE` `MYSQL_USER` `MYSQL_PASSWORD`, plus `MYSQL_URL` on Lambda |
| Valkey | `REDIS_URL` (`rediss://`, TLS) |
| DynamoDB | `TABLE_NAME` |
| S3 | `BUCKET_NAME` |
| SQS | `QUEUE_URL` |

ECS reads passwords from Secrets Manager when a task starts, so it never holds a URL with the password in it. Build the URL in your app from the variables, or let your PostgreSQL client read `PG*` directly.

## Use it

**Stand up the example.** [examples/telehealth](examples/telehealth/) is Tendwell Health, a telehealth company built on this catalog: a platform project, three apps on Lambda and ECS that connect to each other, and teams with their own access. Its `deploy.sh` publishes the catalog to your organization and builds the company in it.

**Sync it to your organization and build your own.** Fork this repository and connect its publish workflow:

1. In Massdriver, turn on **Settings → General → Grant new bundle repositories to all projects**. Create a service account with a **1 year** token in a group allowed to publish.
2. In the fork's **Settings → Secrets and variables → Actions**, add its key as the secret `MASSDRIVER_API_KEY` and your organization ID as the variable `MASSDRIVER_ORG_ID`.
3. Run **Actions → Publish → Run workflow** with *all* ticked. After that, every push to `main` publishes what changed: credentials and resource types first, then bundles.

Then add an AWS IAM Role credential, following the instructions on its form, and deploy `vpc`, `dns-zone` and `ecs-cluster` in each environment. A new DNS zone must be delegated from its parent domain before its certificate is issued; the `dns-zone` operator guide shows how. Each runtime's operator guide has a **Ship your app** walkthrough.

## Repository layout

```
platforms/        Credentials
resource-types/   Contracts between bundles
bundles/          OpenTofu bundles
examples/         Tendwell Health, a telehealth company built on the catalog
.github/workflows Publishing
```

## Versioning

Everything publishes as `0.0.0`, which can be republished in place. Publishing any other version to a repository ends that, development releases included: once a repository holds another version, `0.0.0` can't be overwritten there, and the next change needs a version bump.

## License

[Apache License 2.0](LICENSE).

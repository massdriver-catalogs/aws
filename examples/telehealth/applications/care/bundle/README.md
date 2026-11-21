# Tendwell Care

The clinician portal. Clinicians see the day's booked visits, open a patient's chart, and close an encounter with a visit note. Billing reads closed encounters to file claims.

Runs on the catalog's `ecs-service` runtime: the runtime decides the Fargate service, its load balancer rule, IAM and logs, and this bundle adds the app's contract.

## Needs

- The Visits API (`tendwell-visits-api`), from the Visits project in the same environment.
- PostgreSQL (`aws-postgres`) for encounters.
- Valkey (`aws-valkey`) to cache the visit list.
- An S3 bucket (`aws-s3-bucket`) for visit notes.
- An ECR repository (`aws-ecr-repository`) holding the app image.
- The environment's ECS cluster, VPC and DNS zone, as environment defaults.

## Makes

A `tendwell-care-api` resource with the portal's URL. Billing connects to it.

## Routes

| Route | Does |
|---|---|
| `GET /` | Today's booked visits, from the Visits API |
| `GET /patients/{patient}/chart` | A patient's encounters |
| `POST /encounters` | Close an encounter: `appointment_id`, `patient`, `clinician`, `diagnosis_code`, `note` |
| `GET /encounters?since=<time>` | Encounters closed after a time |
| `GET /health` | Health check |

# Tendwell Visits

The booking API patients use to find an open slot and book a video visit. Every booking puts a message on the reminders queue, and the same app, deployed a second time with **Consume from the queue** on, sends the reminder.

Runs on the catalog's `lambda-function` runtime: the runtime decides the function, its IAM and its logs, and this bundle adds the app's contract.

## Needs

- An HTTP API (`aws-http-api`) to answer on.
- A DynamoDB table (`aws-dynamodb-table`) with `pk` and `sk` string keys, for slots and appointments.
- An SQS queue (`aws-sqs-queue`) for reminders.
- An ECR repository (`aws-ecr-repository`) holding the app image.

## Makes

A `tendwell-visits-api` resource with the API's URL. Care connects to it to list the day's visits.

## Routes

| Route | Does |
|---|---|
| `GET /slots` | Open slots. An empty table gets a day of slots on the first call. |
| `POST /appointments` | Book a slot: `{"slot": "<starts_at>", "patient": "<id>"}` |
| `GET /appointments` | Booked visits |
| `GET /appointments/{id}` | One booking |
| `GET /health` | Health check |

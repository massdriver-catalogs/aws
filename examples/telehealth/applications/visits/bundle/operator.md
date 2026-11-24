---
templating: mustache
---
# Tendwell Visits

## Book a visit by hand

```bash
URL={{#dependencies.api.domain}}https://{{dependencies.api.domain}}{{/dependencies.api.domain}}{{^dependencies.api.domain}}{{dependencies.api.endpoint}}{{/dependencies.api.domain}}
SLOT=$(curl -s $URL/slots | jq -r '.[0].starts_at')
curl -s -X POST $URL/appointments -d "{\"slot\": \"$SLOT\", \"patient\": \"demo-patient\"}" | jq
```

## Booking returns 409

The slot is taken or doesn't exist. Slot IDs are their start times exactly as `GET /slots` returns them, including the time zone.

## Reminders aren't going out

The reminders instance consumes the queue; this one only sends to it. Check the reminders function's logs for `"reminder": "sent"` or `"bounced"`, and how many messages failed every try and moved to the dead-letter queue:

```bash
aws sqs get-queue-attributes --region {{dependencies.queue.region}} \
  --queue-url $(aws sqs get-queue-url --region {{dependencies.queue.region}} \
    --queue-name $(echo {{dependencies.queue.dead_letter_arn}} | cut -d: -f6) --query QueueUrl --output text) \
  --attribute-names ApproximateNumberOfMessages
```

A reminder for Alex Rivera always lands there; their email bounces on purpose.

## Ship a new version

```bash
cd examples/telehealth && ./deploy.sh ship visits <environment>
```

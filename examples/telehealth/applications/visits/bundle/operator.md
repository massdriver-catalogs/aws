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

The reminders instance consumes the queue; this one only sends to it. Check the reminders function's logs for `"reminder": "sent"`, and the queue's dead-letter queue for messages that failed three times:

```bash
aws sqs get-queue-attributes --region {{dependencies.queue.region}} \
  --queue-url {{dependencies.queue.url}} \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
```

## Ship a new version

```bash
cd examples/telehealth && ./deploy.sh ship visits <environment>
```

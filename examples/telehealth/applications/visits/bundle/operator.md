---
templating: mustache
---
# Tendwell Visits

This bundle runs twice: **Visits** answers the booking API, and **Reminder Sender** reads the reminders queue. They share one image.

{{#resources.visits}}
## Book a visit by hand

```bash
URL={{resources.visits.url}}
SLOT=$(curl -s $URL/slots | jq -r '.[0].starts_at')
curl -s -X POST $URL/appointments -d "{\"slot\": \"$SLOT\", \"patient\": \"demo-patient\"}" | jq
```
{{/resources.visits}}

## Booking returns 409

The slot is taken or doesn't exist. Slot IDs are their start times exactly as `GET /slots` returns them, including the time zone.

## Read the logs

```bash
aws logs tail /aws/lambda/{{params.md_metadata.name_prefix}} --region {{dependencies.api.region}} --since 30m --follow
```

## Function errors

- **`KeyError: 'TABLE_NAME'` or `'QUEUE_URL'`:** the Slots table or the Reminders queue isn't linked to this instance. Link it and deploy.
- **`AccessDeniedException` on DynamoDB or SQS:** linked after the last deploy. Deploy this instance.
- **`Task timed out`:** raise **Timeout (seconds)**. Booking makes three AWS calls and should finish well under a second.

## Dead letters on the reminders queue

A reminder that fails every try moves to the dead-letter queue, and the queue's alarm fires. A reminder for **Alex Rivera** always does: their email bounces on purpose, and the front desk calls them instead. Read the bounced reminders:

```bash
DLQ=$(aws sqs get-queue-url --region {{dependencies.queue.region}} \
  --queue-name $(echo {{dependencies.queue.dead_letter_arn}} | cut -d: -f6) --query QueueUrl --output text)
aws sqs receive-message --region {{dependencies.queue.region}} --queue-url $DLQ --max-number-of-messages 10 \
  --visibility-timeout 0 --query 'Messages[].Body' --output text
```

For anyone else, the Reminder Sender's logs say why it failed. After fixing the cause, move them back to the queue from the SQS console with **Start DLQ redrive**.

## Ship a new version

```bash
cd examples/telehealth && ./deploy.sh ship visits <environment>
```

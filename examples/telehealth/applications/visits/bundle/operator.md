---
templating: mustache
---
# Tendwell Visits

{{#resources.visits.url}}
**URL:** {{resources.visits.url}}

{{/resources.visits.url}}
- **Built on:** lambda-function
- **Job:** {{#params.consume_queue}}Reminder Sender. It reads the reminders queue.{{/params.consume_queue}}{{^params.consume_queue}}Visits. It answers the booking API.{{/params.consume_queue}} Both run the same image.
- **Routes:** {{#params.routes}}`{{.}}` {{/params.routes}}{{^params.routes}}none{{/params.routes}}
- **Memory:** {{params.memory_mb}} MB, timeout {{params.timeout_seconds}} seconds
- **Region:** {{dependencies.api.region}}
- **Function and log group:** `{{params.md_metadata.name_prefix}}`, `/aws/lambda/{{params.md_metadata.name_prefix}}`
- **Slots table:** `{{dependencies.table.name}}`
- **Reminders queue:** `{{dependencies.queue.name}}`
- **Image:** `{{params.image_uri}}`

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

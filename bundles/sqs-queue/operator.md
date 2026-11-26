---
templating: mustache
---
# SQS Queue

{{#resources.queue}}
- **Queue:** `{{resources.queue.url}}`
- **Dead-letter queue:** `{{resources.queue.dead_letter_arn}}`
{{/resources.queue}}
- **Region:** {{params.region}}
- **Type:** {{#params.fifo}}FIFO{{/params.fifo}}{{^params.fifo}}standard{{/params.fifo}}
- **Retries:** {{params.max_receive_count}} tries, then the dead-letter queue
- **Visibility timeout:** {{params.visibility_timeout_seconds}} seconds
- **Messages kept:** {{params.message_retention_seconds}} seconds

{{#resources.queue}}
## How many messages are waiting

```bash
aws sqs get-queue-attributes --region {{params.region}} --queue-url {{resources.queue.url}} \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateNumberOfMessagesDelayed
```

`ApproximateNumberOfMessages` is waiting. `NotVisible` is being processed right now.

## Messages are piling up

The waiting count keeps growing.

1. How old is the oldest message?

   ```bash
   aws cloudwatch get-metric-statistics --region {{params.region}} --namespace AWS/SQS \
     --metric-name ApproximateAgeOfOldestMessage --dimensions Name=QueueName,Value={{resources.queue.name}} \
     --start-time $(date -u -v-1H +%FT%TZ 2>/dev/null || date -u -d '-1 hour' +%FT%TZ) --end-time $(date -u +%FT%TZ) \
     --period 300 --statistics Maximum
   ```

   Messages older than {{params.message_retention_seconds}} seconds are deleted unprocessed.

2. Is anything consuming? For a Lambda consumer, find its event source mapping and check that it is `Enabled`:

   ```bash
   aws lambda list-event-source-mappings --region {{params.region}} --event-source-arn {{resources.queue.arn}} \
     --query 'EventSourceMappings[].[UUID,FunctionArn,State,LastProcessingResult]' --output table
   ```

   - **No mapping:** nothing is connected to consume. Connect the consumer to this queue.
   - **`Disabled`:** turn it back on with `aws lambda update-event-source-mapping --uuid <uuid> --enabled`.
   - **`PROBLEM: ...` in the last result:** usually missing permissions. The function's role needs the **consume** policy; redeploying the function's instance reattaches it.

3. Is the consumer failing? A high `NotVisible` count with a flat waiting count usually means consumers time out and messages come back. Check the consumer's logs for timeouts, and raise **Processing time limit** if work really takes that long.

4. Is the consumer too slow? Messages arrive faster than they are finished. Raise the consumer's concurrency or batch size.

## Messages are in the dead-letter queue

Each message there failed {{params.max_receive_count}} times. Count them and look at a few, without removing them:

```bash
DLQ_ARN={{resources.queue.dead_letter_arn}}
DLQ_URL=$(aws sqs get-queue-url --region {{params.region}} --queue-name "${DLQ_ARN##*:}" --query QueueUrl --output text)
aws sqs get-queue-attributes --region {{params.region}} --queue-url "$DLQ_URL" --attribute-names ApproximateNumberOfMessages
aws sqs receive-message --region {{params.region}} --queue-url "$DLQ_URL" --max-number-of-messages 5 \
  --visibility-timeout 0 --attribute-names All
```

Find the bug from the message bodies and the consumer's logs, and deploy the fix before moving messages back.

## Move messages back from the dead-letter queue

{{#resources.queue.dead_letter_arn}}
After the consumer is fixed, move every message back to the main queue:

```bash
aws sqs start-message-move-task --region {{params.region}} \
  --source-arn {{resources.queue.dead_letter_arn}} --destination-arn {{resources.queue.arn}}
```

Watch it, and stop it if the messages start failing again:

```bash
aws sqs list-message-move-tasks --region {{params.region}} --source-arn {{resources.queue.dead_letter_arn}}
aws sqs cancel-message-move-task --region {{params.region}} --task-handle <TaskHandle>
```

To throttle the move, add `--max-number-of-messages-per-second 10`.
{{/resources.queue.dead_letter_arn}}

## Throw away messages

Only when the messages are worthless. Purging can't be undone and runs once per 60 seconds:

```bash
aws sqs purge-queue --region {{params.region}} --queue-url {{resources.queue.url}}
```

## Sending fails with AccessDenied

The sender's role doesn't have the **send** policy. Check who has each one:

```bash
{{#resources.queue.policies}}
aws iam list-entities-for-policy --policy-arn {{arn}} --query 'PolicyRoles[].RoleName'   # {{name}}
{{/resources.queue.policies}}
```

{{#params.fifo}}
## Sending fails with MissingParameter

This is a FIFO queue. Every message needs `--message-group-id`. Messages in one group are processed one at a time, so use many groups (for example, one per customer) for throughput.
{{/params.fifo}}
{{/resources.queue}}

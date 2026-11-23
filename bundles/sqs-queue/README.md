# SQS Queue

A queue for background work. One part of an app sends messages; a worker or Lambda function takes them off and does the work later.

## What it needs

An AWS account to deploy into.

## What it makes

- The queue, encrypted at rest with an SQS-managed key. Receives wait up to 20 seconds for a message, which cuts the number of empty, billed requests.
- A dead-letter queue. A message that fails **Attempts before dead-letter** times moves there, so one bad message can't block the rest. It keeps messages for 14 days.
- Two IAM policies, **send** and **consume**. An app attaches one to its own role. Consume covers receive, delete, change visibility and reading queue attributes, which is what a Lambda event source needs.
- Alarms when the oldest message has waited longer than **Alarm when a message waits longer than**, and when any message reaches the dead-letter queue.

## Processing time limit

When a consumer receives a message, the message is hidden from others for **Processing time limit**. If the consumer doesn't delete it in time, the message comes back and counts as a failed attempt. Set the limit well above the slowest normal processing time. For Lambda, AWS recommends at least six times the function's timeout.

## FIFO

A **Strict order (FIFO)** queue delivers each message once, in order within its message group. Senders must set a message group ID. Duplicate messages sent within 5 minutes are dropped based on their content, or on a deduplication ID if the sender sets one. FIFO can't be turned on or off for an existing queue.

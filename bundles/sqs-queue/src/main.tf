locals {
  # FIFO queue names must end in .fifo, and a FIFO queue's dead-letter queue must be FIFO too.
  suffix = var.fifo ? ".fifo" : ""
  name   = var.md_metadata.name_prefix
}

resource "aws_sqs_queue" "dead_letter" {
  name                    = "${local.name}-dlq${local.suffix}"
  fifo_queue              = var.fifo
  sqs_managed_sse_enabled = true

  # Standard queues keep a message's original enqueue time when it moves here,
  # so the dead-letter queue keeps messages for the longest time SQS allows.
  message_retention_seconds = 1209600
}

resource "aws_sqs_queue" "main" {
  name                        = "${local.name}${local.suffix}"
  fifo_queue                  = var.fifo
  content_based_deduplication = var.fifo ? true : null
  visibility_timeout_seconds  = var.visibility_timeout_seconds
  message_retention_seconds   = var.message_retention_seconds
  receive_wait_time_seconds   = 20
  sqs_managed_sse_enabled     = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dead_letter.arn
    maxReceiveCount     = var.max_receive_count
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dead_letter" {
  queue_url = aws_sqs_queue.dead_letter.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.main.arn]
  })
}

resource "aws_iam_policy" "send" {
  name        = "${local.name}-send"
  description = "Send messages to the ${local.name} SQS queue"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage", "sqs:GetQueueUrl", "sqs:GetQueueAttributes"]
      Resource = aws_sqs_queue.main.arn
    }]
  })
}

resource "aws_iam_policy" "consume" {
  name        = "${local.name}-consume"
  description = "Receive and delete messages from the ${local.name} SQS queue"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:ChangeMessageVisibility",
        "sqs:GetQueueAttributes",
        "sqs:GetQueueUrl",
      ]
      Resource = aws_sqs_queue.main.arn
    }]
  })
}

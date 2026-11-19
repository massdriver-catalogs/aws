# Consumers bind access by attaching one of these policy ARNs to their own
# role (aws_iam_role_policy_attachment), so the queue owns its permissions.
resource "massdriver_resource" "queue" {
  field = "queue"
  name  = "SQS ${aws_sqs_queue.main.name}"
  resource = jsonencode({
    name            = aws_sqs_queue.main.name
    arn             = aws_sqs_queue.main.arn
    url             = aws_sqs_queue.main.url
    region          = var.region
    dead_letter_arn = aws_sqs_queue.dead_letter.arn
    policies = [
      { name = "send", arn = aws_iam_policy.send.arn },
      { name = "consume", arn = aws_iam_policy.consume.arn },
    ]
  })
}

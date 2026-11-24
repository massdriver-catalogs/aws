module "alarm_channel" {
  source      = "massdriver-cloud/aws-alarm-channel/massdriver"
  version     = "~> 0.1"
  md_metadata = var.md_metadata
}

module "backlog" {
  source  = "massdriver-cloud/aws-metric-alarm/massdriver"
  version = "~> 1.0"

  md_metadata   = var.md_metadata
  sns_topic_arn = module.alarm_channel.arn

  alarm_name   = "${local.name}-backlog"
  display_name = "Messages waiting too long"
  message      = "The oldest message in ${local.name} has waited over ${var.max_message_age_minutes} minutes. Consumers are down or can't keep up."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = var.max_message_age_minutes * 60

  metric_name = "ApproximateAgeOfOldestMessage"
  namespace   = "AWS/SQS"
  period      = 300
  statistic   = "Maximum"
  dimensions  = { QueueName = aws_sqs_queue.main.name }
}

module "dead_letters" {
  source  = "massdriver-cloud/aws-metric-alarm/massdriver"
  version = "~> 1.0"

  md_metadata   = var.md_metadata
  sns_topic_arn = module.alarm_channel.arn

  alarm_name   = "${local.name}-dead-letters"
  display_name = "Messages failing"
  message      = "Messages failed ${var.max_receive_count} times and moved to ${aws_sqs_queue.dead_letter.name}."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 0

  metric_name = "ApproximateNumberOfMessagesVisible"
  namespace   = "AWS/SQS"
  period      = 300
  statistic   = "Maximum"
  dimensions  = { QueueName = aws_sqs_queue.dead_letter.name }
}

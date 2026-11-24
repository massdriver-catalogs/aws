module "alarm_channel" {
  source      = "massdriver-cloud/aws-alarm-channel/massdriver"
  version     = "~> 0.1"
  md_metadata = var.md_metadata
}

# On-demand tables still throttle on a hot key or a sudden jump past the
# table's previous peak.
module "throttles" {
  source  = "massdriver-cloud/aws-metric-alarm/massdriver"
  version = "~> 1.0"

  md_metadata   = var.md_metadata
  sns_topic_arn = module.alarm_channel.arn

  alarm_name   = "${local.name}-throttles"
  display_name = "Requests throttled"
  message      = "${local.name} throttled more than 10 reads or writes in 5 minutes. Look for a hot partition key."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 10

  metric_queries = {
    reads = {
      metric = {
        metric_name = "ReadThrottleEvents"
        namespace   = "AWS/DynamoDB"
        period      = 300
        stat        = "Sum"
        dimensions  = { TableName = aws_dynamodb_table.main.name }
      }
    }
    writes = {
      metric = {
        metric_name = "WriteThrottleEvents"
        namespace   = "AWS/DynamoDB"
        period      = 300
        stat        = "Sum"
        dimensions  = { TableName = aws_dynamodb_table.main.name }
      }
    }
    throttles = {
      expression  = "reads + writes"
      label       = "Throttled requests"
      return_data = true
    }
  }
  display_metric_key = "writes"
}

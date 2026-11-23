module "alarm_channel" {
  source      = "massdriver-cloud/aws-alarm-channel/massdriver"
  version     = "~> 0.1"
  md_metadata = var.md_metadata
}

module "errors" {
  source  = "massdriver-cloud/aws-metric-alarm/massdriver"
  version = "~> 1.0"

  md_metadata   = var.md_metadata
  sns_topic_arn = module.alarm_channel.arn

  alarm_name   = "${local.name}-errors"
  display_name = "Function errors"
  message      = "${local.name} threw errors or timed out on more than 5 invocations in 5 minutes."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 5

  metric_name = "Errors"
  namespace   = "AWS/Lambda"
  period      = 300
  statistic   = "Sum"
  dimensions  = { FunctionName = aws_lambda_function.main.function_name }
}

module "throttles" {
  source  = "massdriver-cloud/aws-metric-alarm/massdriver"
  version = "~> 1.0"

  md_metadata   = var.md_metadata
  sns_topic_arn = module.alarm_channel.arn

  alarm_name   = "${local.name}-throttles"
  display_name = "Function throttled"
  message      = "${local.name} was throttled more than 5 times in 5 minutes. The account's concurrency limit is exhausted."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 5

  metric_name = "Throttles"
  namespace   = "AWS/Lambda"
  period      = 300
  statistic   = "Sum"
  dimensions  = { FunctionName = aws_lambda_function.main.function_name }
}

# Slow invocations become timeouts; this warns before they cross the line.
module "duration" {
  source  = "massdriver-cloud/aws-metric-alarm/massdriver"
  version = "~> 1.0"

  md_metadata   = var.md_metadata
  sns_topic_arn = module.alarm_channel.arn

  alarm_name   = "${local.name}-duration"
  display_name = "Close to timing out"
  message      = "5% of ${local.name} invocations took over 80% of the ${var.timeout_seconds}s timeout for 15 minutes."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = var.timeout_seconds * 1000 * 0.8

  metric_queries = {
    p95 = {
      metric = {
        metric_name = "Duration"
        namespace   = "AWS/Lambda"
        period      = 300
        stat        = "p95"
        dimensions  = { FunctionName = aws_lambda_function.main.function_name }
      }
      return_data = true
    }
  }
  display_metric_key = "p95"
}

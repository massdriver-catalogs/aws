locals {
  cache_dimensions = { clusterId = aws_elasticache_serverless_cache.main.name }
}

module "alarm_channel" {
  source      = "massdriver-cloud/aws-alarm-channel/massdriver"
  version     = "~> 0.1"
  md_metadata = var.md_metadata
}

# At the limit, keys are evicted or writes fail.
module "storage" {
  source  = "massdriver-cloud/aws-metric-alarm/massdriver"
  version = "~> 1.0"

  md_metadata   = var.md_metadata
  sns_topic_arn = module.alarm_channel.arn

  alarm_name   = "${local.name}-storage"
  display_name = "Close to the storage limit"
  message      = "${local.name} holds over 80% of its ${var.max_data_storage_gb} GB limit. Raise Data storage limit before keys are evicted."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = var.max_data_storage_gb * 1024 * 1024 * 1024 * 0.8

  metric_name = "BytesUsedForCache"
  namespace   = "AWS/ElastiCache"
  period      = 300
  statistic   = "Maximum"
  dimensions  = local.cache_dimensions
}

# At the limit, requests are throttled.
module "requests" {
  source  = "massdriver-cloud/aws-metric-alarm/massdriver"
  version = "~> 1.0"

  md_metadata   = var.md_metadata
  sns_topic_arn = module.alarm_channel.arn

  alarm_name   = "${local.name}-ecpu"
  display_name = "Close to the request limit"
  message      = "${local.name} has used over 80% of its ${var.max_ecpu_per_second} ECPUs per second for 5 minutes. Raise Request limit before requests are throttled."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 5
  threshold           = var.max_ecpu_per_second * 60 * 0.8

  metric_name = "ElastiCacheProcessingUnits"
  namespace   = "AWS/ElastiCache"
  period      = 60
  statistic   = "Sum"
  dimensions  = local.cache_dimensions
}

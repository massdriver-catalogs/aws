module "alarm_channel" {
  source      = "massdriver-cloud/aws-alarm-channel/massdriver"
  version     = "~> 0.1"
  md_metadata = var.md_metadata
}

module "cpu" {
  source  = "massdriver-cloud/aws-metric-alarm/massdriver"
  version = "~> 1.0"

  md_metadata   = var.md_metadata
  sns_topic_arn = module.alarm_channel.arn

  alarm_name   = "${local.name}-cpu"
  display_name = "CPU high"
  message      = "${local.name} PostgreSQL has averaged over 80% CPU for 15 minutes. Look for slow queries, or move to a larger instance class."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = 80

  metric_name = "CPUUtilization"
  namespace   = "AWS/RDS"
  period      = 300
  statistic   = "Average"
  dimensions  = { DBInstanceIdentifier = aws_db_instance.main.identifier }
}

# Storage autoscaling also acts at 10% free, after 5 minutes. Fifteen minutes
# rides out a growth, so this fires when autoscaling is off or at its maximum.
# The threshold is set from Storage, so after autoscaling grows the disk it
# fires later than 10%.
module "free_storage" {
  source  = "massdriver-cloud/aws-metric-alarm/massdriver"
  version = "~> 1.0"

  md_metadata   = var.md_metadata
  sns_topic_arn = module.alarm_channel.arn

  alarm_name   = "${local.name}-storage"
  display_name = "Running out of storage"
  message      = "${local.name} PostgreSQL has under 10% of its storage free. Writes stop when it's full; raise Storage or Grow storage up to."

  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  threshold           = var.storage_gb * 1024 * 1024 * 1024 * 0.1

  metric_name = "FreeStorageSpace"
  namespace   = "AWS/RDS"
  period      = 300
  statistic   = "Minimum"
  dimensions  = { DBInstanceIdentifier = aws_db_instance.main.identifier }
}

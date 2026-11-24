locals {
  ecs_dimensions = { ClusterName = var.cluster.name, ServiceName = aws_ecs_service.main.name }
  # ALB metrics key on ARN suffixes, not full ARNs.
  alb_dimensions = local.public ? {
    LoadBalancer = regex("loadbalancer/(.+)$", var.cluster.load_balancer.arn)[0]
    TargetGroup  = aws_lb_target_group.main[0].arn_suffix
  } : null
}

module "alarm_channel" {
  source      = "massdriver-cloud/aws-alarm-channel/massdriver"
  version     = "~> 0.1"
  md_metadata = var.md_metadata
}

# Autoscaling holds CPU at the target, so a sustained 80% means it's out of room.
module "cpu" {
  source  = "massdriver-cloud/aws-metric-alarm/massdriver"
  version = "~> 1.0"

  md_metadata   = var.md_metadata
  sns_topic_arn = module.alarm_channel.arn

  alarm_name   = "${local.name}-cpu"
  display_name = "CPU high"
  message      = "${local.name} has averaged over 80% CPU for 15 minutes. Raise Most tasks when busy or the task size."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = 80

  metric_name = "CPUUtilization"
  namespace   = "AWS/ECS"
  period      = 300
  statistic   = "Average"
  dimensions  = local.ecs_dimensions
}

# Fargate kills a task that runs out of memory; this warns before it does.
module "memory" {
  source  = "massdriver-cloud/aws-metric-alarm/massdriver"
  version = "~> 1.0"

  md_metadata   = var.md_metadata
  sns_topic_arn = module.alarm_channel.arn

  alarm_name   = "${local.name}-memory"
  display_name = "Memory high"
  message      = "${local.name} has averaged over 80% memory for 15 minutes. Tasks are killed when they run out; raise the task size."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = 80

  metric_name = "MemoryUtilization"
  namespace   = "AWS/ECS"
  period      = 300
  statistic   = "Average"
  dimensions  = local.ecs_dimensions
}

module "unhealthy_tasks" {
  source  = "massdriver-cloud/aws-metric-alarm/massdriver"
  version = "~> 1.0"
  count   = local.public ? 1 : 0

  md_metadata   = var.md_metadata
  sns_topic_arn = module.alarm_channel.arn

  alarm_name   = "${local.name}-unhealthy"
  display_name = "Tasks failing health checks"
  message      = "A task of ${local.name} has failed its health check (${local.health}) for 3 minutes."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = 0

  metric_name = "UnHealthyHostCount"
  namespace   = "AWS/ApplicationELB"
  period      = 60
  statistic   = "Maximum"
  dimensions  = local.alb_dimensions
}

module "server_errors" {
  source  = "massdriver-cloud/aws-metric-alarm/massdriver"
  version = "~> 1.0"
  count   = local.public ? 1 : 0

  md_metadata   = var.md_metadata
  sns_topic_arn = module.alarm_channel.arn

  alarm_name   = "${local.name}-5xx"
  display_name = "Server errors"
  message      = "More than 5% of requests to ${local.name} returned 5xx over 5 minutes."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 5

  metric_queries = {
    errors = {
      metric = {
        metric_name = "HTTPCode_Target_5XX_Count"
        namespace   = "AWS/ApplicationELB"
        period      = 300
        stat        = "Sum"
        dimensions  = local.alb_dimensions
      }
    }
    requests = {
      metric = {
        metric_name = "RequestCount"
        namespace   = "AWS/ApplicationELB"
        period      = 300
        stat        = "Sum"
        dimensions  = local.alb_dimensions
      }
    }
    # A handful of requests in a quiet period shouldn't page anyone.
    error_rate = {
      expression  = "IF(requests > 20, 100 * errors / requests, 0)"
      label       = "5xx rate (%)"
      return_data = true
    }
  }
  display_metric_key = "errors"
}

module "slow_responses" {
  source  = "massdriver-cloud/aws-metric-alarm/massdriver"
  version = "~> 1.0"
  count   = local.public ? 1 : 0

  md_metadata   = var.md_metadata
  sns_topic_arn = module.alarm_channel.arn

  alarm_name   = "${local.name}-latency"
  display_name = "Slow responses"
  message      = "${local.name} took over ${var.slow_response_ms} ms to answer 5% of requests for 15 minutes."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = var.slow_response_ms / 1000

  metric_queries = {
    p95 = {
      metric = {
        metric_name = "TargetResponseTime"
        namespace   = "AWS/ApplicationELB"
        period      = 300
        stat        = "p95"
        dimensions  = local.alb_dimensions
      }
      return_data = true
    }
  }
  display_metric_key = "p95"
}

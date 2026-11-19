locals {
  name      = var.md_metadata.name_prefix
  has_image = var.image != ""
  image     = local.has_image ? var.image : "public.ecr.aws/nginx/nginx:stable-alpine"
  port      = local.has_image ? var.port : 80
  health    = local.has_image ? var.health_check_path : "/"

  cpu    = tonumber(split("/", var.size)[0])
  memory = tonumber(split("/", var.size)[1])

  public = var.subdomain != ""
  fqdn   = var.dns != null ? "${var.subdomain}.${var.dns.domain}" : var.subdomain

  private_subnets = [for s in var.network.subnets : s.id if s.tier == "private"]

  client_security_groups = compact([
    try(var.postgres.client_security_group_id, null),
    try(var.mariadb.client_security_group_id, null),
    try(var.cache.client_security_group_id, null),
  ])
}

resource "aws_cloudwatch_log_group" "main" {
  name              = "/ecs/${local.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_security_group" "task" {
  name        = local.name
  description = "Tasks of ${local.name}"
  vpc_id      = var.network.id
}

resource "aws_vpc_security_group_ingress_rule" "alb" {
  count                        = local.public ? 1 : 0
  security_group_id            = aws_security_group.task.id
  description                  = "Load balancer to the container port"
  ip_protocol                  = "tcp"
  from_port                    = local.port
  to_port                      = local.port
  referenced_security_group_id = var.cluster.load_balancer.security_group_id
}

# Tasks pull images, call AWS APIs and reach whatever the app talks to, through
# the VPC's egress; the destinations aren't known here.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.task.id
  description       = "Outbound through the VPC egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_ecs_task_definition" "main" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = local.cpu
  memory                   = local.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.architecture == "arm64" ? "ARM64" : "X86_64"
  }

  container_definitions = jsonencode([{
    name      = "app"
    image     = local.image
    essential = true
    portMappings = [{
      containerPort = local.port
      protocol      = "tcp"
    }]
    environment = [for k, v in local.environment : { name = k, value = v }]
    secrets     = local.secrets
    # Lets ECS Exec sessions and signals reach the app's child processes.
    linuxParameters = { initProcessEnabled = true }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.main.name
        awslogs-region        = var.cluster.region
        awslogs-stream-prefix = "app"
      }
    }
  }])
}

resource "aws_lb_target_group" "main" {
  count       = local.public ? 1 : 0
  vpc_id      = var.network.id
  target_type = "ip"
  protocol    = "HTTP"
  # Tasks register with the container port; this one is only a default, so
  # it stays fixed and a port change doesn't replace the group.
  port                 = 80
  deregistration_delay = 30

  health_check {
    path                = local.health
    matcher             = "200-399"
    interval            = 15
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = {
    Name = local.name
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_lb_listener_rule" "main" {
  count        = local.public ? 1 : 0
  listener_arn = var.cluster.load_balancer.listener_arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main[0].arn
  }

  condition {
    host_header {
      values = [local.fqdn]
    }
  }

  lifecycle {
    precondition {
      condition     = var.dns != null
      error_message = "Subdomain \"${var.subdomain}\" needs a DNS zone connected to this service. Connect one, or clear Subdomain to run a worker with no address."
    }
  }
}

resource "aws_route53_record" "main" {
  count   = local.public && var.dns != null ? 1 : 0
  zone_id = var.dns.zone_id
  name    = local.fqdn
  type    = "A"

  alias {
    name                   = var.cluster.load_balancer.dns_name
    zone_id                = var.cluster.load_balancer.zone_id
    evaluate_target_health = true
  }
}

resource "aws_ecs_service" "main" {
  name                   = local.name
  cluster                = var.cluster.arn
  task_definition        = aws_ecs_task_definition.main.arn
  desired_count          = var.desired_count
  platform_version       = "LATEST"
  enable_execute_command = true
  propagate_tags         = "SERVICE"
  wait_for_steady_state  = true

  health_check_grace_period_seconds = local.public ? 60 : null

  capacity_provider_strategy {
    capacity_provider = var.spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }

  network_configuration {
    subnets          = local.private_subnets
    security_groups  = concat([aws_security_group.task.id], local.client_security_groups)
    assign_public_ip = false
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  dynamic "load_balancer" {
    for_each = local.public ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.main[0].arn
      container_name   = "app"
      container_port   = local.port
    }
  }

  # Autoscaling owns the running count between Tasks and the maximum.
  lifecycle {
    ignore_changes = [desired_count]

    precondition {
      condition     = length(local.private_subnets) > 0
      error_message = "The connected VPC has no private subnets. Tasks run in private subnets."
    }
    precondition {
      condition     = var.cluster.region == var.network.region
      error_message = "The cluster is in ${var.cluster.region} but the VPC is in ${var.network.region}. Connect the VPC the cluster uses."
    }
    precondition {
      condition     = !var.spot || var.architecture == "x86_64"
      error_message = "Fargate Spot doesn't run arm64 tasks. Set Architecture to x86_64, or turn Spot off."
    }
    precondition {
      condition     = var.max_count >= var.desired_count
      error_message = "Most tasks when busy (${var.max_count}) is below Tasks (${var.desired_count})."
    }
  }

  depends_on = [aws_lb_listener_rule.main]
}

# A warning, not a failure: a VPC with endpoints for ECR, logs and SSM works
# without egress, and this bundle can't see them.
check "egress" {
  assert {
    condition     = var.network.internet_egress
    error_message = "The VPC has no internet egress. Tasks can't pull public images, reach AWS APIs or open ECS Exec sessions unless the VPC has endpoints for them."
  }
}

resource "aws_appautoscaling_target" "main" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${var.cluster.name}/${aws_ecs_service.main.name}"
  min_capacity       = var.desired_count
  max_capacity       = var.max_count
}

resource "aws_appautoscaling_policy" "cpu" {
  count              = var.max_count > var.desired_count ? 1 : 0
  name               = "${local.name}-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = aws_appautoscaling_target.main.service_namespace
  scalable_dimension = aws_appautoscaling_target.main.scalable_dimension
  resource_id        = aws_appautoscaling_target.main.resource_id

  target_tracking_scaling_policy_configuration {
    target_value       = var.cpu_target
    scale_in_cooldown  = 300
    scale_out_cooldown = 60
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}

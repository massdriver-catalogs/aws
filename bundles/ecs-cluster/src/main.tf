locals {
  name     = var.md_metadata.name_prefix
  has_zone = var.dns != null

  public_subnets = [for s in var.network.subnets : s.id if s.tier == "public"]
  public_zones   = distinct([for s in var.network.subnets : s.availability_zone_id if s.tier == "public"])
}

resource "aws_ecs_cluster" "main" {
  name = local.name

  setting {
    name  = "containerInsights"
    value = var.container_insights
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Internet-facing load balancer for ${local.name}"
  vpc_id      = var.network.id
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  security_group_id = aws_security_group.alb.id
  description       = "HTTP from the internet"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "https" {
  count             = local.has_zone ? 1 : 0
  security_group_id = aws_security_group.alb.id
  description       = "HTTPS from the internet"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

# Services pick their own container ports, so the load balancer may reach any
# port inside the VPC; each service's own group decides what it accepts.
resource "aws_vpc_security_group_egress_rule" "vpc" {
  security_group_id = aws_security_group.alb.id
  description       = "Service tasks inside the VPC"
  ip_protocol       = "tcp"
  from_port         = 0
  to_port           = 65535
  cidr_ipv4         = var.network.cidr
}

resource "aws_lb" "main" {
  load_balancer_type         = "application"
  internal                   = false
  subnets                    = local.public_subnets
  security_groups            = [aws_security_group.alb.id]
  drop_invalid_header_fields = true
  enable_deletion_protection = var.deletion_protection

  tags = {
    Name = local.name
  }

  dynamic "access_logs" {
    for_each = var.access_logs ? [1] : []
    content {
      bucket  = aws_s3_bucket.logs[0].id
      enabled = true
    }
  }

  lifecycle {
    precondition {
      condition     = length(local.public_zones) >= 2
      error_message = "A load balancer needs public subnets in at least two availability zones. The connected VPC has public subnets in ${length(local.public_zones)}."
    }
    precondition {
      condition     = !local.has_zone || try(var.dns.region, "") == var.network.region
      error_message = "The DNS zone's certificate is in ${try(var.dns.region, "")}, but the VPC is in ${var.network.region}. A load balancer can only use a certificate from its own region."
    }
  }

  depends_on = [aws_s3_bucket_policy.logs]
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = local.has_zone ? [1] : []
    content {
      type = "redirect"
      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = local.has_zone ? [] : [1]
    content {
      type = "fixed-response"
      fixed_response {
        content_type = "text/plain"
        message_body = "Not found"
        status_code  = "404"
      }
    }
  }
}

resource "aws_lb_listener" "https" {
  count             = local.has_zone ? 1 : 0
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.dns.certificate_arn

  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not found"
      status_code  = "404"
    }
  }
}

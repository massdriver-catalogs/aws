resource "massdriver_resource" "cluster" {
  field = "cluster"
  name  = "ECS ${local.name}"
  # Services take the VPC and zone from the cluster, so they can't be pointed
  # at a different VPC than the load balancer or a zone its certificate doesn't cover.
  resource = jsonencode(merge({
    name   = aws_ecs_cluster.main.name
    arn    = aws_ecs_cluster.main.arn
    region = var.network.region
    load_balancer = {
      arn               = aws_lb.main.arn
      dns_name          = aws_lb.main.dns_name
      zone_id           = aws_lb.main.zone_id
      security_group_id = aws_security_group.alb.id
      listener_arn      = local.has_zone ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
      protocol          = local.has_zone ? "HTTPS" : "HTTP"
    }
    network = {
      id                 = var.network.id
      private_subnet_ids = local.private_subnets
      internet_egress    = var.network.internet_egress
    }
    }, local.has_zone ? {
    zone = { zone_id = var.dns.zone_id, domain = var.dns.domain }
  } : {}))
}

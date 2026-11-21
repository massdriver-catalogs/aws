resource "massdriver_resource" "cluster" {
  field = "cluster"
  name  = "ECS ${local.name}"
  resource = jsonencode({
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
  })
}

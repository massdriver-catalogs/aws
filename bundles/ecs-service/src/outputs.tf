output "url" {
  value = local.public ? "${lower(coalesce(var.cluster.load_balancer.protocol, "HTTPS"))}://${local.fqdn}" : ""
}

output "hostname" {
  value = local.public ? local.fqdn : ""
}

output "service_name" {
  value = aws_ecs_service.main.name
}

output "region" {
  value = var.cluster.region
}

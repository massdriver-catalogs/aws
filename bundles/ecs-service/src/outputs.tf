output "url" {
  value = local.public ? "https://${local.fqdn}" : ""
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

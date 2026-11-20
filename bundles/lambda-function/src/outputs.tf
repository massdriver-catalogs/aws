output "url" {
  value = try(var.api.domain, null) != null ? "https://${var.api.domain}" : var.api.endpoint
}

output "function_name" {
  value = aws_lambda_function.main.function_name
}

output "region" {
  value = local.region
}

resource "massdriver_resource" "api" {
  field = "api"
  name  = "HTTP API ${local.name}"
  resource = jsonencode(merge(
    {
      id            = aws_apigatewayv2_api.main.id
      region        = var.region
      endpoint      = local.custom_domain ? "https://${local.domain}" : aws_apigatewayv2_api.main.api_endpoint
      execution_arn = aws_apigatewayv2_api.main.execution_arn
    },
    local.custom_domain ? { domain = local.domain } : {},
  ))

  # The endpoint is only usable once the name resolves.
  depends_on = [aws_route53_record.main, aws_apigatewayv2_api_mapping.main]
}

locals {
  name          = var.md_metadata.name_prefix
  custom_domain = var.dns != null && var.subdomain != ""
  domain        = local.custom_domain ? "${var.subdomain}.${var.dns.domain}" : null
}

resource "aws_apigatewayv2_api" "main" {
  name          = local.name
  protocol_type = "HTTP"

  dynamic "cors_configuration" {
    for_each = length(var.cors_allowed_origins) > 0 ? [1] : []
    content {
      allow_origins = var.cors_allowed_origins
      allow_methods = ["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"]
      allow_headers = ["authorization", "content-type"]
      max_age       = 3600
    }
  }
}

resource "aws_cloudwatch_log_group" "access" {
  name              = "/aws/apigateway/${local.name}"
  retention_in_days = var.access_log_retention_days
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_rate_limit  = var.throttle_rate
    throttling_burst_limit = var.throttle_burst
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      ip               = "$context.identity.sourceIp"
      requestTime      = "$context.requestTime"
      routeKey         = "$context.routeKey"
      status           = "$context.status"
      responseLength   = "$context.responseLength"
      latencyMs        = "$context.responseLatency"
      integrationError = "$context.integrationErrorMessage"
    })
  }
}

resource "aws_apigatewayv2_domain_name" "main" {
  count       = local.custom_domain ? 1 : 0
  domain_name = local.domain

  domain_name_configuration {
    certificate_arn = var.dns.certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }

  lifecycle {
    precondition {
      # A regional API can only use an ACM certificate from its own region.
      condition     = var.dns.region == var.region
      error_message = "The DNS zone's certificate is in ${var.dns.region}, but this API is in ${var.region}. A custom domain needs both in the same region: use a DNS zone from ${var.region}, or clear Subdomain."
    }
  }
}

resource "aws_apigatewayv2_api_mapping" "main" {
  count       = local.custom_domain ? 1 : 0
  api_id      = aws_apigatewayv2_api.main.id
  domain_name = aws_apigatewayv2_domain_name.main[0].id
  stage       = aws_apigatewayv2_stage.default.id
}

resource "aws_route53_record" "main" {
  count   = local.custom_domain ? 1 : 0
  zone_id = var.dns.zone_id
  name    = local.domain
  type    = "A"

  alias {
    name                   = aws_apigatewayv2_domain_name.main[0].domain_name_configuration[0].target_domain_name
    zone_id                = aws_apigatewayv2_domain_name.main[0].domain_name_configuration[0].hosted_zone_id
    evaluate_target_health = false
  }
}

check "subdomain_needs_zone" {
  assert {
    condition     = var.subdomain == "" || var.dns != null
    error_message = "Subdomain is set to \"${var.subdomain}\", but no DNS zone is connected, so the API has no custom domain. Connect a DNS zone and redeploy."
  }
}

resource "aws_wafv2_web_acl" "main" {
  count = var.waf ? 1 : 0
  name  = local.name
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = ["AWSManagedRulesCommonRuleSet", "AWSManagedRulesKnownBadInputsRuleSet"]
    content {
      name     = rule.value
      priority = rule.key

      override_action {
        none {}
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.value
        }
      }

      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "${local.name}-${rule.value}"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = local.name
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "main" {
  count        = var.waf ? 1 : 0
  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.main[0].arn
}

# WAF only writes to log groups whose names start with aws-waf-logs-.
resource "aws_cloudwatch_log_group" "waf" {
  count             = var.waf ? 1 : 0
  name              = "aws-waf-logs-${local.name}"
  retention_in_days = var.access_log_retention_days
}

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  count                   = var.waf ? 1 : 0
  resource_arn            = aws_wafv2_web_acl.main[0].arn
  log_destination_configs = [aws_cloudwatch_log_group.waf[0].arn]

  # Only blocked requests are logged; allowed ones are in the access logs.
  logging_filter {
    default_behavior = "DROP"
    filter {
      behavior    = "KEEP"
      requirement = "MEETS_ANY"
      condition {
        action_condition {
          action = "BLOCK"
        }
      }
    }
  }
}

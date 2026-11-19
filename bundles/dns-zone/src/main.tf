locals {
  name        = var.md_metadata.name_prefix
  create_zone = var.hosted_zone.source == "create"

  zone_id      = local.create_zone ? aws_route53_zone.main[0].zone_id : data.aws_route53_zone.existing[0].zone_id
  name_servers = local.create_zone ? aws_route53_zone.main[0].name_servers : data.aws_route53_zone.existing[0].name_servers
}

# Records made by other bundles must be removed by them, so decommissioning
# never deletes a zone that still serves something.
resource "aws_route53_zone" "main" {
  count         = local.create_zone ? 1 : 0
  name          = var.domain
  comment       = "Managed by Massdriver (${local.name})"
  force_destroy = false
}

data "aws_route53_zone" "existing" {
  count   = local.create_zone ? 0 : 1
  zone_id = try(var.hosted_zone.zone_id, null)

  lifecycle {
    postcondition {
      condition     = trimsuffix(self.name, ".") == var.domain
      error_message = "Hosted zone ${try(var.hosted_zone.zone_id, "")} is for ${trimsuffix(self.name, ".")}, not ${var.domain}."
    }
    postcondition {
      condition     = !self.private_zone
      error_message = "Hosted zone ${try(var.hosted_zone.zone_id, "")} is private. Certificates can only be validated in a public zone."
    }
  }
}

resource "aws_acm_certificate" "main" {
  domain_name               = var.domain
  subject_alternative_names = ["*.${var.domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }

  tags = { Name = var.domain }
}

# The domain and its wildcard share one validation record, so both keys write
# the same name and value.
resource "aws_route53_record" "validation" {
  for_each = {
    for o in aws_acm_certificate.main.domain_validation_options : o.domain_name => o
  }

  zone_id         = local.zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "main" {
  certificate_arn         = aws_acm_certificate.main.arn
  validation_record_fqdns = [for r in aws_route53_record.validation : r.fqdn]

  timeouts {
    create = "${var.validation_timeout_minutes}m"
  }
}

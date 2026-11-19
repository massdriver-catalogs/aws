resource "massdriver_resource" "zone" {
  field = "zone"
  name  = var.domain
  resource = jsonencode({
    zone_id         = local.zone_id
    domain          = var.domain
    region          = var.region
    certificate_arn = aws_acm_certificate_validation.main.certificate_arn
    name_servers    = local.name_servers
  })
}

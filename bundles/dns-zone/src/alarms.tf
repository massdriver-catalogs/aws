module "alarm_channel" {
  source      = "massdriver-cloud/aws-alarm-channel/massdriver"
  version     = "~> 0.1"
  md_metadata = var.md_metadata
}

# ACM renews 60 days before expiry. Under 30 days left means renewal is failing,
# usually because the validation record or the delegation is gone.
module "certificate_expiry" {
  source  = "massdriver-cloud/aws-metric-alarm/massdriver"
  version = "~> 1.0"

  md_metadata   = var.md_metadata
  sns_topic_arn = module.alarm_channel.arn

  alarm_name   = "${local.name}-certificate-expiry"
  display_name = "Certificate not renewing"
  message      = "The certificate for ${var.domain} expires in under 30 days. ACM could not renew it."

  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  threshold           = 30

  metric_name = "DaysToExpiry"
  namespace   = "AWS/CertificateManager"
  period      = 86400
  statistic   = "Minimum"
  dimensions  = { CertificateArn = aws_acm_certificate_validation.main.certificate_arn }
}

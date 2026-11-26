locals {
  # A zone that already existed is signed, or not, by whoever owns it.
  dnssec = local.create_zone && try(var.hosted_zone.dnssec, null) == true
}

data "aws_caller_identity" "current" {}

# Route 53 only signs with keys in us-east-1, whatever region the certificate is in.
resource "aws_kms_key" "dnssec" {
  count                    = local.dnssec ? 1 : 0
  provider                 = aws.us_east_1
  description              = "${local.name} DNSSEC signing"
  customer_master_key_spec = "ECC_NIST_P256"
  key_usage                = "SIGN_VERIFY"
  deletion_window_in_days  = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "Route53DNSSEC"
        Effect    = "Allow"
        Principal = { Service = "dnssec-route53.amazonaws.com" }
        Action    = ["kms:DescribeKey", "kms:GetPublicKey", "kms:Sign", "kms:Verify"]
        Resource  = "*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
          ArnLike      = { "aws:SourceArn" = "arn:aws:route53:::hostedzone/*" }
        }
      },
      {
        Sid       = "Route53DNSSECGrant"
        Effect    = "Allow"
        Principal = { Service = "dnssec-route53.amazonaws.com" }
        Action    = "kms:CreateGrant"
        Resource  = "*"
        Condition = { Bool = { "kms:GrantIsForAWSResource" = "true" } }
      },
      {
        Sid       = "AccountIAM"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
    ]
  })
}

resource "aws_route53_key_signing_key" "main" {
  count                      = local.dnssec ? 1 : 0
  hosted_zone_id             = aws_route53_zone.main[0].id
  key_management_service_arn = aws_kms_key.dnssec[0].arn
  name                       = "massdriver"
}

resource "aws_route53_hosted_zone_dnssec" "main" {
  count          = local.dnssec ? 1 : 0
  hosted_zone_id = aws_route53_key_signing_key.main[0].hosted_zone_id
}

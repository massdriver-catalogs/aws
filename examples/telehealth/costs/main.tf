terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Cost and Usage Report definitions only exist in us-east-1.
provider "aws" {
  region = "us-east-1"
}

variable "organization" {
  type = string
}

# Off by default: activation only succeeds in the payer account, and only once
# AWS has seen the tag in billing data.
variable "cost_allocation_tags" {
  type    = list(string)
  default = []
}

# Named per organization, so it sits beside any setup the account already has.
module "cur" {
  source               = "github.com/massdriver-cloud/integrations//aws-cost-and-usage-reports?ref=44df319"
  name_prefix          = "massdriver-costs-${var.organization}"
  bucket_region        = "us-east-1"
  cost_allocation_tags = var.cost_allocation_tags
}

output "massdriver_integration_config" {
  value     = module.cur.massdriver_integration_config
  sensitive = true
}

# Massdriver only reads a report named massdriver-costs, and the account's
# only one lives in this bucket. Its manifests name this bucket, so a copy of
# them in the bucket above still sends readers here.
variable "shared_report_bucket" {
  type    = string
  default = "massdriver-costs-a4202874"
}

resource "aws_iam_user_policy" "shared_report" {
  name = "massdriver-costs-${var.organization}-shared-report"
  user = "massdriver-costs-${var.organization}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.shared_report_bucket}"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${var.shared_report_bucket}/*"
      }
    ]
  })

  depends_on = [module.cur]
}

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

variable "organization" {
  type = string
}

# Massdriver only reads a Cost and Usage Report named massdriver-costs, and an
# account can hold just one report by that name, so every organization in the
# account reads the same one instead of getting its own.
variable "report_bucket" {
  type    = string
  default = "massdriver-costs-a4202874"
}

variable "report_bucket_region" {
  type    = string
  default = "us-west-2"
}

resource "aws_iam_user" "massdriver_costs" {
  name = "massdriver-costs-${var.organization}"
  tags = { "managed-by" = "massdriver" }
}

resource "aws_iam_user_policy" "massdriver_costs" {
  name = "massdriver-costs-${var.organization}-policy"
  user = aws_iam_user.massdriver_costs.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:aws:s3:::${var.report_bucket}"
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "arn:aws:s3:::${var.report_bucket}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["tag:GetResources"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_access_key" "massdriver_costs" {
  user = aws_iam_user.massdriver_costs.name
}

output "massdriver_integration_config" {
  value = {
    access_key_id     = aws_iam_access_key.massdriver_costs.id
    secret_access_key = aws_iam_access_key.massdriver_costs.secret
    bucket_name       = var.report_bucket
    bucket_region     = var.report_bucket_region
  }
  sensitive = true
}

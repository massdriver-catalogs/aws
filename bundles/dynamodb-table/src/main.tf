locals {
  name         = var.md_metadata.name_prefix
  has_sort_key = try(var.sort_key.name, "") != ""
  has_ttl      = var.ttl_attribute != ""
  kms          = var.encryption == "KMS"

  table_resources = [aws_dynamodb_table.main.arn, "${aws_dynamodb_table.main.arn}/index/*"]
  read_actions = [
    "dynamodb:GetItem",
    "dynamodb:BatchGetItem",
    "dynamodb:Query",
    "dynamodb:Scan",
    "dynamodb:DescribeTable",
    "dynamodb:ConditionCheckItem",
  ]
  write_actions = [
    "dynamodb:PutItem",
    "dynamodb:UpdateItem",
    "dynamodb:DeleteItem",
    "dynamodb:BatchWriteItem",
  ]
  kms_statements = local.kms ? [{
    Effect   = "Allow"
    Action   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
    Resource = aws_kms_key.table[0].arn
  }] : []
}

data "aws_caller_identity" "current" {}

resource "aws_kms_key" "table" {
  count               = local.kms ? 1 : 0
  description         = "${local.name} DynamoDB table"
  enable_key_rotation = true

  # The account's own IAM policies decide who can use the key, so the read and
  # read-write policies below are all a consumer needs.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AccountIAM"
      Effect    = "Allow"
      Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "kms:*"
      Resource  = "*"
    }]
  })
}

resource "aws_dynamodb_table" "main" {
  name                        = local.name
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = var.partition_key.name
  range_key                   = local.has_sort_key ? var.sort_key.name : null
  table_class                 = var.table_class
  deletion_protection_enabled = var.deletion_protection

  attribute {
    name = var.partition_key.name
    type = var.partition_key.type
  }

  dynamic "attribute" {
    for_each = local.has_sort_key ? [var.sort_key] : []
    content {
      name = attribute.value.name
      type = attribute.value.type
    }
  }

  ttl {
    enabled        = local.has_ttl
    attribute_name = local.has_ttl ? var.ttl_attribute : ""
  }

  point_in_time_recovery {
    enabled = var.point_in_time_recovery
  }

  # Disabled here means the AWS-owned key, which is free; DynamoDB always encrypts at rest.
  server_side_encryption {
    enabled     = local.kms
    kms_key_arn = local.kms ? aws_kms_key.table[0].arn : null
  }
}

resource "aws_iam_policy" "read" {
  name        = "${local.name}-read"
  description = "Read items from the ${local.name} DynamoDB table"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([{
      Effect   = "Allow"
      Action   = local.read_actions
      Resource = local.table_resources
    }], local.kms_statements)
  })
}

resource "aws_iam_policy" "read_write" {
  name        = "${local.name}-read-write"
  description = "Read and write items in the ${local.name} DynamoDB table"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([{
      Effect   = "Allow"
      Action   = concat(local.read_actions, local.write_actions)
      Resource = local.table_resources
    }], local.kms_statements)
  })
}

data "aws_caller_identity" "current" {}

locals {
  # Bucket names are global across all AWS accounts; the account ID keeps this one unique.
  name    = "${var.md_metadata.name_prefix}-${data.aws_caller_identity.current.account_id}"
  kms     = var.encryption == "KMS"
  has_ttl = var.object_expiration_days > 0

  kms_read_statements = local.kms ? [{
    Effect   = "Allow"
    Action   = ["kms:Decrypt", "kms:DescribeKey"]
    Resource = aws_kms_key.bucket[0].arn
  }] : []
  kms_write_statements = local.kms ? [{
    Effect   = "Allow"
    Action   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey*", "kms:DescribeKey"]
    Resource = aws_kms_key.bucket[0].arn
  }] : []
}

resource "aws_kms_key" "bucket" {
  count               = local.kms ? 1 : 0
  description         = "${local.name} S3 bucket"
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

resource "aws_s3_bucket" "main" {
  bucket = local.name

  lifecycle {
    precondition {
      condition     = length(local.name) <= 63
      error_message = "The bucket name ${local.name} is over S3's 63-character limit. Use shorter project, environment or instance names."
    }
  }
}

resource "aws_s3_bucket_public_access_block" "main" {
  bucket                  = aws_s3_bucket.main.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "main" {
  bucket = aws_s3_bucket.main.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "main" {
  bucket = aws_s3_bucket.main.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.kms ? "aws:kms" : "AES256"
      kms_master_key_id = local.kms ? aws_kms_key.bucket[0].arn : null
    }
    # Caches the data key per bucket, cutting KMS request charges by up to 99%.
    bucket_key_enabled = local.kms
  }
}

# Suspended rather than Disabled: S3 can't return a bucket to unversioned once
# versioning has been on.
resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id
  versioning_configuration {
    status = var.versioning ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "main" {
  bucket     = aws_s3_bucket.main.id
  depends_on = [aws_s3_bucket_versioning.main]

  rule {
    id     = "cleanup"
    status = "Enabled"
    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }

    expiration {
      days                         = local.has_ttl ? var.object_expiration_days : null
      expired_object_delete_marker = local.has_ttl ? null : true
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "main" {
  count  = length(var.cors_allowed_origins) > 0 ? 1 : 0
  bucket = aws_s3_bucket.main.id

  cors_rule {
    allowed_origins = var.cors_allowed_origins
    allowed_methods = ["GET", "HEAD", "PUT", "POST"]
    allowed_headers = ["*"]
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

resource "aws_s3_bucket_policy" "main" {
  bucket     = aws_s3_bucket.main.id
  depends_on = [aws_s3_bucket_public_access_block.main]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.main.arn, "${aws_s3_bucket.main.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_iam_policy" "read" {
  name        = "${var.md_metadata.name_prefix}-read"
  description = "Read files from the ${local.name} S3 bucket"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation"]
        Resource = aws_s3_bucket.main.arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion", "s3:GetObjectAttributes"]
        Resource = "${aws_s3_bucket.main.arn}/*"
      },
    ], local.kms_read_statements)
  })
}

resource "aws_iam_policy" "read_write" {
  name        = "${var.md_metadata.name_prefix}-read-write"
  description = "Read and write files in the ${local.name} S3 bucket"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"]
        Resource = aws_s3_bucket.main.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion",
          "s3:GetObjectAttributes",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:AbortMultipartUpload",
          "s3:ListMultipartUploadParts",
        ]
        Resource = "${aws_s3_bucket.main.arn}/*"
      },
    ], local.kms_write_statements)
  })
}

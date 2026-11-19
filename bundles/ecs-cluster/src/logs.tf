data "aws_caller_identity" "current" {}
data "aws_elb_service_account" "main" {}

resource "aws_s3_bucket" "logs" {
  count         = var.access_logs ? 1 : 0
  bucket_prefix = "${substr(local.name, 0, 30)}-alb-"

  # The logs describe this load balancer's traffic; decommissioning it
  # shouldn't stall on a non-empty bucket.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "logs" {
  count                   = var.access_logs ? 1 : 0
  bucket                  = aws_s3_bucket.logs[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "logs" {
  count  = var.access_logs ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

# Load balancers can only write access logs to buckets encrypted with S3-managed keys.
resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  count  = var.access_logs ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  count  = var.access_logs ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id

  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = var.access_log_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 1
    }
  }
}

# Regions older than August 2022 deliver logs from a regional ELB account;
# newer ones use the log delivery service. Allowing both works everywhere.
resource "aws_s3_bucket_policy" "logs" {
  count  = var.access_logs ? 1 : 0
  bucket = aws_s3_bucket.logs[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "ElbAccount"
        Effect    = "Allow"
        Principal = { AWS = data.aws_elb_service_account.main.arn }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.logs[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Sid       = "LogDelivery"
        Effect    = "Allow"
        Principal = { Service = "logdelivery.elasticloadbalancing.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.logs[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
      },
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.logs[0].arn, "${aws_s3_bucket.logs[0].arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
    ]
  })
  depends_on = [aws_s3_bucket_public_access_block.logs]
}

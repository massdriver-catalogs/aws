# Consumers bind access by attaching one of these policy ARNs to their own
# role (aws_iam_role_policy_attachment), so the bucket owns its permissions.
resource "massdriver_resource" "bucket" {
  field = "bucket"
  name  = "S3 ${local.name}"
  resource = jsonencode({
    name   = aws_s3_bucket.main.bucket
    arn    = aws_s3_bucket.main.arn
    region = var.region
    policies = [
      { name = "read-write", arn = aws_iam_policy.read_write.arn },
      { name = "read", arn = aws_iam_policy.read.arn },
    ]
  })
}

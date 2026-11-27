resource "massdriver_resource" "policy" {
  field = "policy"
  name  = "Scale ${var.service_name_prefix}* on ${var.cluster.name}"
  resource = jsonencode({
    name        = aws_iam_policy.main.name
    arn         = aws_iam_policy.main.arn
    description = aws_iam_policy.main.description
  })
}

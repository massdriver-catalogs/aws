locals {
  name = var.md_metadata.name_prefix

  # arn:aws:ecs:<region>:<account>:cluster/<name> names its services
  # arn:aws:ecs:<region>:<account>:service/<name>/<service>.
  services = "${replace(var.cluster.arn, ":cluster/", ":service/")}/${var.service_name_prefix}*"
}

resource "aws_iam_policy" "main" {
  name        = local.name
  description = "Set the task count of ${var.service_name_prefix}* services on ${var.cluster.name}"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Sid      = "ScaleServices"
        Effect   = "Allow"
        Action   = ["ecs:DescribeServices", "ecs:UpdateService"]
        Resource = local.services
      }],
      # UpdateService can also swap a service's task definition, capacity or
      # network. A different task definition would run under that
      # definition's role, so only the task count may change.
      [
        for key in ["ecs:task-definition", "ecs:capacity-provider", "ecs:subnet", "ecs:enable-execute-command", "ecs:auto-assign-public-ip"] : {
          Sid       = "OnlyTheCount${replace(title(replace(split(":", key)[1], "-", " ")), " ", "")}"
          Effect    = "Deny"
          Action    = "ecs:UpdateService"
          Resource  = local.services
          Condition = { Null = { (key) = "false" } }
        }
      ],
    )
  })
}

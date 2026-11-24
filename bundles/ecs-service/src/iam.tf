locals {
  ecs_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  task_app_policies = merge([
    for k, d in local.app_dependencies : {
      for p in d.value.policies : "${k}-${p.name}" => p.arn if contains(local.task_policies[d.type], p.name)
    } if contains(keys(local.task_policies), d.type)
  ]...)

  execution_app_policies = merge([
    for k, d in local.app_dependencies : { for p in d.value.policies : "${k}-${p.name}" => p.arn } if contains(local.execution_policies, d.type)
  ]...)

  pull_policies = merge(
    var.codebase == null ? {} : { for p in var.codebase.registry.policies : "codebase-${p.name}" => p.arn if p.name == "pull" },
    local.execution_app_policies,
  )
}

resource "aws_iam_role" "execution" {
  name_prefix        = "${substr(local.name, 0, 28)}-exec-"
  assume_role_policy = local.ecs_trust
}

resource "aws_iam_role_policy" "execution_logs" {
  name = "write-logs"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.main.arn}:*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "execution" {
  for_each   = local.pull_policies
  role       = aws_iam_role.execution.name
  policy_arn = each.value
}

# Services that pulled through a registry connection now pull through the
# codebase. Moving keeps the attachment instead of detaching the same policy.
moved {
  from = aws_iam_role_policy_attachment.execution["registry-pull"]
  to   = aws_iam_role_policy_attachment.execution["codebase-pull"]
}

resource "aws_iam_role" "task" {
  name_prefix        = "${substr(local.name, 0, 28)}-task-"
  assume_role_policy = local.ecs_trust
}

resource "aws_iam_role_policy" "exec" {
  name = "ecs-exec"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "task" {
  for_each   = local.task_app_policies
  role       = aws_iam_role.task.name
  policy_arn = each.value
}

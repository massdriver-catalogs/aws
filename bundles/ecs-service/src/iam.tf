locals {
  ecs_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  # Each store publishes its own policies; an unset access choice gets them all.
  store_policies = merge(
    var.table == null ? {} : (try(length(var.table_access) > 0, false) ? { table = var.table_access } : { for p in var.table.policies : "table-${p.name}" => p.arn }),
    var.bucket == null ? {} : (try(length(var.bucket_access) > 0, false) ? { bucket = var.bucket_access } : { for p in var.bucket.policies : "bucket-${p.name}" => p.arn }),
    var.queue == null ? {} : (try(length(var.queue_access) > 0, false) ? { queue = var.queue_access } : { for p in var.queue.policies : "queue-${p.name}" => p.arn }),
  )

  # The databases' policies grant reading their secrets, which ECS does on the
  # task's behalf before the container starts.
  pull_policies = merge(
    var.codebase == null ? {} : { for p in var.codebase.registry.policies : "codebase-${p.name}" => p.arn if p.name == "pull" },
    var.postgres == null ? {} : { for p in var.postgres.policies : "postgres-${p.name}" => p.arn },
    var.mariadb == null ? {} : { for p in var.mariadb.policies : "mariadb-${p.name}" => p.arn },
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
  for_each   = local.store_policies
  role       = aws_iam_role.task.name
  policy_arn = each.value
}

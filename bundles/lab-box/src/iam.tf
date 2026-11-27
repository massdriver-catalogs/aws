data "aws_iam_policy_document" "assume_task" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "execution" {
  name_prefix        = "${substr(local.name, 0, 28)}-exec-"
  assume_role_policy = data.aws_iam_policy_document.assume_task.json
}

resource "aws_iam_role_policy" "execution" {
  name = "logs-and-secrets"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.main.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_secretsmanager_secret.main.arn
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.main.arn
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "execution" {
  for_each   = { for p in var.codebase.registry.policies : "codebase-${p.name}" => p.arn if p.name == "pull" }
  role       = aws_iam_role.execution.name
  policy_arn = each.value
}

# The agent runs whatever commands it decides to, so its AWS role can do
# nothing but open the admin shell, mount the home directory, and reach the
# lab's own saves table. Only the game server is given the role's credentials.
resource "aws_iam_role" "task" {
  name_prefix        = "${substr(local.name, 0, 28)}-task-"
  assume_role_policy = data.aws_iam_policy_document.assume_task.json
}

resource "aws_iam_role_policy" "task" {
  name = "exec-and-home"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["elasticfilesystem:ClientMount", "elasticfilesystem:ClientWrite"]
        Resource = aws_efs_file_system.home.arn
        Condition = {
          StringEquals = { "elasticfilesystem:AccessPointArn" = aws_efs_access_point.home.arn }
        }
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "gamedata" {
  for_each   = var.gamedata == null ? {} : { for p in var.gamedata.policies : p.name => p.arn if p.name == "read-write" }
  role       = aws_iam_role.task.name
  policy_arn = each.value
}

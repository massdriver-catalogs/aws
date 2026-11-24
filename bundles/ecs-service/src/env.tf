locals {
  # An application running on this bundle declares its own variables in its
  # app block; Massdriver renders them here before the step runs.
  app_envs = try(jsondecode(file("/massdriver/envs.json")), {})
  # Its secrets go to Secrets Manager and ECS injects them at start, so they never
  # appear in the task definition.
  app_secrets = try(jsondecode(file("/massdriver/secrets.json")), {})

  # An app points a variable at a Secrets Manager value, like a database's
  # secret_arn + ":password::", and ECS injects it at start instead of the
  # value landing in the task definition.
  secret_ref = "^arn:aws[a-z-]*:secretsmanager:"

  environment = merge(
    { for k, v in local.app_envs : k => v if !can(regex(local.secret_ref, v)) },
    { for e in var.environment : e.name => e.value },
    { PORT = tostring(local.port) },
  )

  secrets = concat(
    [for k, v in local.app_envs : { name = k, valueFrom = v } if can(regex(local.secret_ref, v))],
    # Pinned to the version, so a changed value makes a new task definition
    # and rolls the tasks instead of waiting for them to restart.
    [for k in keys(local.app_secrets) : { name = k, valueFrom = "${aws_secretsmanager_secret_version.app[0].secret_id}:${k}::${aws_secretsmanager_secret_version.app[0].version_id}" }],
  )
}

resource "aws_secretsmanager_secret" "app" {
  count                   = length(local.app_secrets) > 0 ? 1 : 0
  name_prefix             = "${local.name}-app-"
  description             = "Secrets ${local.name}'s app declares, set in Massdriver"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "app" {
  count         = length(local.app_secrets) > 0 ? 1 : 0
  secret_id     = aws_secretsmanager_secret.app[0].id
  secret_string = jsonencode(local.app_secrets)
}

resource "aws_iam_role_policy" "execution_app_secrets" {
  count = length(local.app_secrets) > 0 ? 1 : 0
  name  = "read-app-secrets"
  role  = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "secretsmanager:GetSecretValue"
      Resource = aws_secretsmanager_secret.app[0].arn
    }]
  })
}

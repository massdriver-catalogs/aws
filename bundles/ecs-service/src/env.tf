locals {
  # An application running on this bundle declares its own variables in its
  # app block; Massdriver renders them here before the step runs.
  app_envs = try(jsondecode(file("/massdriver/envs.json")), {})
  # Its secrets go to Secrets Manager and ECS injects them at start, so they never
  # appear in the task definition.
  app_secrets = try(jsondecode(file("/massdriver/secrets.json")), {})

  # Passwords are injected from Secrets Manager, so connection URLs that would
  # embed them (DATABASE_URL, MYSQL_URL) aren't built.
  environment = merge(
    local.app_envs,
    { for e in var.environment : e.name => e.value },
    { PORT = tostring(local.port) },
    var.postgres == null ? {} : {
      PGHOST     = var.postgres.hostname
      PGPORT     = tostring(var.postgres.port)
      PGDATABASE = var.postgres.database
      PGUSER     = var.postgres.username
    },
    var.mariadb == null ? {} : {
      MYSQL_HOST     = var.mariadb.hostname
      MYSQL_PORT     = tostring(var.mariadb.port)
      MYSQL_DATABASE = var.mariadb.database
      MYSQL_USER     = var.mariadb.username
    },
    var.cache == null ? {} : {
      REDIS_URL = "rediss://${var.cache.hostname}:${var.cache.port}"
    },
    var.table == null ? {} : { TABLE_NAME = var.table.name },
    var.bucket == null ? {} : { BUCKET_NAME = var.bucket.name },
    var.queue == null ? {} : { QUEUE_URL = var.queue.url },
  )

  secrets = concat(
    var.postgres == null ? [] : [{ name = "PGPASSWORD", valueFrom = "${var.postgres.secret_arn}:password::" }],
    var.mariadb == null ? [] : [{ name = "MYSQL_PASSWORD", valueFrom = "${var.mariadb.secret_arn}:password::" }],
    # Through the version, so tasks don't start before the values exist.
    [for k in keys(local.app_secrets) : { name = k, valueFrom = "${aws_secretsmanager_secret_version.app[0].secret_id}:${k}::" }],
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

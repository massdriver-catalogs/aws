locals {
  # An application running on this bundle declares its own variables in its
  # app block; Massdriver renders them here before the step runs.
  app_envs = try(jsondecode(file("/massdriver/envs.json")), {})

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
  )
}

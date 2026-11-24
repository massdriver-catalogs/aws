data "aws_partition" "current" {}

locals {
  name   = var.md_metadata.name_prefix
  engine = "mariadb"
  port   = 3306
  family = "mariadb${var.engine_version}"

  internal_subnets = [for s in var.network.subnets : s if s.tier == "internal"]
  private_subnets  = [for s in var.network.subnets : s if s.tier == "private"]
  db_subnets       = length(local.internal_subnets) > 0 ? local.internal_subnets : local.private_subnets

  # Deletion protection already blocks destroy, so a final snapshot is only
  # skipped when both settings agree the data can go.
  skip_final_snapshot = !var.deletion_protection && var.skip_final_snapshot

  log_exports = ["error", "slowquery"]
}

resource "aws_db_subnet_group" "main" {
  name       = local.name
  subnet_ids = [for s in local.db_subnets : s.id]

  lifecycle {
    precondition {
      condition     = length(distinct([for s in local.db_subnets : s.availability_zone_id])) >= 2
      error_message = "RDS needs internal or private subnets in at least two availability zones in the VPC."
    }
  }
}

resource "aws_security_group" "client" {
  name        = "${local.name}-client"
  description = "Attach to anything that connects to ${local.name}"
  vpc_id      = var.network.id
}

resource "aws_security_group" "database" {
  name        = "${local.name}-db"
  description = "${local.name} MariaDB, reachable from the client group only"
  vpc_id      = var.network.id
}

resource "aws_vpc_security_group_ingress_rule" "from_clients" {
  security_group_id            = aws_security_group.database.id
  description                  = "MariaDB from ${local.name}-client"
  referenced_security_group_id = aws_security_group.client.id
  ip_protocol                  = "tcp"
  from_port                    = local.port
  to_port                      = local.port
}

resource "aws_db_parameter_group" "main" {
  name_prefix = "${local.name}-${replace(local.family, ".", "-")}-"
  family      = local.family

  # RDS for MariaDB 10.11 and later only knows the log_slow_* names.
  parameter {
    name  = "log_slow_query"
    value = "1"
  }

  parameter {
    name  = "log_slow_query_time"
    value = "1"
  }

  # CloudWatch export reads log files, not tables.
  parameter {
    name  = "log_output"
    value = "FILE"
  }

  parameter {
    name  = "require_secure_transport"
    value = "1"
  }

  # A major upgrade needs a group for the new family before the old one can go.
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "exports" {
  for_each          = toset(local.log_exports)
  name              = "/aws/rds/instance/${local.name}/${each.key}"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "monitoring" {
  count = var.enhanced_monitoring ? 1 : 0
  name  = "${local.name}-rds-monitoring"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "monitoring.rds.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "monitoring" {
  count      = var.enhanced_monitoring ? 1 : 0
  role       = aws_iam_role.monitoring[0].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}

resource "random_password" "main" {
  length  = 40
  special = false
  keepers = {
    version = var.password_version
  }
}

resource "random_id" "final_snapshot" {
  byte_length = 4
}

resource "aws_db_instance" "main" {
  identifier     = local.name
  engine         = local.engine
  engine_version = var.engine_version
  instance_class = var.instance_class
  port           = local.port

  db_name  = var.database_name
  username = var.username
  password = random_password.main.result

  allocated_storage     = var.storage_gb
  max_allocated_storage = var.storage_max_gb
  storage_type          = "gp3"
  storage_encrypted     = true

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.database.id]
  publicly_accessible    = false
  multi_az               = var.multi_az
  parameter_group_name   = aws_db_parameter_group.main.name
  ca_cert_identifier     = "rds-ca-rsa2048-g1"

  iam_database_authentication_enabled = true
  auto_minor_version_upgrade          = true
  allow_major_version_upgrade         = true
  apply_immediately                   = true

  backup_retention_period   = var.backup_retention_days
  copy_tags_to_snapshot     = true
  deletion_protection       = var.deletion_protection
  skip_final_snapshot       = local.skip_final_snapshot
  final_snapshot_identifier = local.skip_final_snapshot ? null : "${local.name}-final-${random_id.final_snapshot.hex}"
  delete_automated_backups  = local.skip_final_snapshot

  enabled_cloudwatch_logs_exports       = local.log_exports
  performance_insights_enabled          = var.performance_insights
  performance_insights_retention_period = var.performance_insights ? 7 : null
  monitoring_interval                   = var.enhanced_monitoring ? 60 : 0
  monitoring_role_arn                   = var.enhanced_monitoring ? aws_iam_role.monitoring[0].arn : null

  depends_on = [
    aws_cloudwatch_log_group.exports,
    aws_iam_role_policy_attachment.monitoring,
  ]

  lifecycle {
    precondition {
      condition     = var.storage_max_gb == 0 || var.storage_max_gb > var.storage_gb
      error_message = "Grow storage up to must be 0 or larger than Storage."
    }
    precondition {
      condition     = !var.performance_insights || !contains(["db.t4g.micro", "db.t4g.small"], var.instance_class)
      error_message = "Performance Insights needs db.t4g.medium or larger on MariaDB."
    }
  }
}

resource "aws_secretsmanager_secret" "main" {
  name_prefix             = "${local.name}-"
  description             = "Credentials for ${local.name} MariaDB"
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "main" {
  secret_id = aws_secretsmanager_secret.main.id
  secret_string = jsonencode({
    username = aws_db_instance.main.username
    password = random_password.main.result
    engine   = local.engine
    host     = aws_db_instance.main.address
    port     = aws_db_instance.main.port
    dbname   = aws_db_instance.main.db_name
  })
}

resource "aws_iam_policy" "read_secret" {
  name        = "${local.name}-read-secret"
  description = "Read the ${local.name} MariaDB credentials"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource = aws_secretsmanager_secret.main.arn
    }]
  })
}

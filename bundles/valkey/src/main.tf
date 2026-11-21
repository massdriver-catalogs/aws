locals {
  name = var.md_metadata.name_prefix

  # Serverless Valkey uses 6379 for reads and writes and 6380 for reads from replicas.
  port        = 6379
  reader_port = 6380

  internal_subnets = [for s in var.network.subnets : s if s.tier == "internal"]
  private_subnets  = [for s in var.network.subnets : s if s.tier == "private"]
  cache_subnets    = length(local.internal_subnets) > 0 ? local.internal_subnets : local.private_subnets

  # ElastiCache takes at most one subnet per availability zone.
  subnets_by_az = { for s in local.cache_subnets : s.availability_zone_id => s.id... }
  subnet_ids    = slice([for az, ids in local.subnets_by_az : ids[0]], 0, min(3, length(local.subnets_by_az)))
}

resource "aws_security_group" "client" {
  name        = "${local.name}-client"
  description = "Attach to anything that connects to ${local.name}"
  vpc_id      = var.network.id
}

resource "aws_security_group" "cache" {
  name        = "${local.name}-cache"
  description = "${local.name} Valkey, reachable from the client group only"
  vpc_id      = var.network.id
}

resource "aws_vpc_security_group_ingress_rule" "from_clients" {
  security_group_id            = aws_security_group.cache.id
  description                  = "Valkey from ${local.name}-client"
  referenced_security_group_id = aws_security_group.client.id
  ip_protocol                  = "tcp"
  from_port                    = local.port
  to_port                      = local.reader_port
}

resource "aws_elasticache_serverless_cache" "main" {
  name                 = local.name
  description          = "${local.name} Valkey"
  engine               = "valkey"
  major_engine_version = var.major_engine_version
  subnet_ids           = local.subnet_ids
  security_group_ids   = [aws_security_group.cache.id]

  cache_usage_limits {
    data_storage {
      maximum = var.max_data_storage_gb
      unit    = "GB"
    }
    ecpu_per_second {
      maximum = var.max_ecpu_per_second
    }
  }

  snapshot_retention_limit = var.snapshot_retention_days
  daily_snapshot_time      = var.snapshot_retention_days > 0 ? "04:00" : null

  lifecycle {
    precondition {
      condition     = length(local.subnet_ids) >= 2
      error_message = "Valkey needs internal or private subnets in at least two availability zones in the VPC."
    }
  }
}

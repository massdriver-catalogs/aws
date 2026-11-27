locals {
  name = var.md_metadata.name_prefix

  cpu    = tonumber(split("/", var.size)[0])
  memory = tonumber(split("/", var.size)[1])

  agent_port = 4096
  game_port  = 8080

  # Fargate gives the task a new IP on every start; this name follows it.
  namespace = "${local.name}.internal"
  hostname  = "box.${local.namespace}"

  # Bundle secrets are not OpenTofu variables. The provisioner writes them here.
  app_secrets = try(jsondecode(file("/massdriver/secrets.json")), {})
  secret_env  = { for k in ["ANTHROPIC_API_KEY", "LAB_PASSWORD"] : k => local.app_secrets[k] if lookup(local.app_secrets, k, "") != "" }

  environment = merge(
    {
      PLAYER_NAME = var.player_name
      PLAYER_AGE  = tostring(var.player_age)
      LAB_MODEL   = var.model
      AGENT_PORT  = tostring(local.agent_port)
      GAME_PORT   = tostring(local.game_port)
    },
    var.postgres == null ? {} : {
      PGHOST     = var.postgres.hostname
      PGPORT     = tostring(var.postgres.port)
      PGDATABASE = var.postgres.database
      PGUSER     = var.postgres.username
      PGSSLMODE  = "require"
    },
    var.cache == null ? {} : {
      REDIS_URL = "rediss://${var.cache.hostname}:${var.cache.port}"
    },
  )

  # Read when the task starts, so the database password never lands in the
  # task definition.
  database_secrets = var.postgres == null ? [] : [{ name = "PGPASSWORD", valueFrom = "${var.postgres.secret_arn}:password::" }]

  client_security_groups = compact([
    try(var.postgres.client_security_group_id, ""),
    try(var.cache.client_security_group_id, ""),
  ])

  # A digest rather than a tag, so a restarted task runs the image that was
  # deployed, not whatever was pushed since.
  image = "${var.codebase.registry.url}@${data.aws_ecr_image.lab.image_digest}"
}

data "aws_ecr_image" "lab" {
  registry_id     = var.codebase.registry.registry_id
  repository_name = var.codebase.registry.name
  image_tag       = var.image_tag == "" ? null : var.image_tag
  most_recent     = var.image_tag == "" ? true : null

  lifecycle {
    precondition {
      condition     = var.codebase.registry.region == var.cluster.region
      error_message = "The codebase's image repository is in ${var.codebase.registry.region} and the cluster in ${var.cluster.region}. Use a codebase in the cluster's region."
    }
  }
}

data "aws_vpc" "main" {
  id = var.cluster.network.id
}

resource "aws_kms_key" "main" {
  description             = "Secrets, logs and home directory of ${local.name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  # In a key policy, resource "*" is this key.
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "Account"
        Effect    = "Allow"
        Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        # CloudWatch Logs encrypts with the key itself, so the key policy must allow the service.
        Sid       = "CloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.cluster.region}.amazonaws.com" }
        Action    = ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
        Resource  = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:${data.aws_partition.current.partition}:logs:${var.cluster.region}:${data.aws_caller_identity.current.account_id}:log-group:/ecs/${local.name}"
          }
        }
      },
    ]
  })
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name}"
  target_key_id = aws_kms_key.main.key_id
}

resource "aws_cloudwatch_log_group" "main" {
  name              = "/ecs/${local.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_secretsmanager_secret" "main" {
  name_prefix             = "${local.name}-"
  description             = "Keys of the ${local.name} lab box"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "main" {
  secret_id     = aws_secretsmanager_secret.main.id
  secret_string = jsonencode(local.secret_env)

  lifecycle {
    precondition {
      condition     = contains(keys(local.secret_env), "LAB_PASSWORD")
      error_message = "Set the LAB_PASSWORD secret on this instance. The agent can run any command in the box, so it never listens without a password."
    }
  }
}

resource "aws_service_discovery_private_dns_namespace" "main" {
  name        = local.namespace
  description = "Private name of the ${local.name} lab box"
  vpc         = var.cluster.network.id
}

resource "aws_service_discovery_service" "box" {
  name = "box"

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.main.id
    routing_policy = "MULTIVALUE"
    dns_records {
      type = "A"
      ttl  = 10
    }
  }

  health_check_custom_config {}

  # The AWS provider reads this block back differently from how it's written
  # and plans a replacement on every deploy, which Cloud Map refuses while the
  # task is registered.
  lifecycle {
    ignore_changes = [health_check_custom_config]
  }
}

resource "aws_security_group" "task" {
  name        = local.name
  description = "The ${local.name} lab box"
  vpc_id      = var.cluster.network.id
}

# The agent calls Claude, and installs packages from npm when a game needs them.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.task.id
  description       = "Outbound through the VPC egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# Whatever proxies to the box runs inside the VPC; nothing outside it can reach
# these ports, and the box has no public address.
resource "aws_vpc_security_group_ingress_rule" "vpc" {
  for_each = {
    agent = local.agent_port
    game  = local.game_port
  }

  security_group_id = aws_security_group.task.id
  description       = "The ${each.key} port from the VPC"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  cidr_ipv4         = data.aws_vpc.main.cidr_block
}

resource "aws_ecs_task_definition" "main" {
  family                   = local.name
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = local.cpu
  memory                   = local.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.architecture == "arm64" ? "ARM64" : "X86_64"
  }

  volume {
    name = "home"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.home.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.home.id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([{
    name        = "lab"
    image       = local.image
    essential   = true
    environment = [for k in sort(keys(local.environment)) : { name = k, value = local.environment[k] }]
    # The version id makes a new task definition when a secret changes, so
    # the task restarts with it.
    secrets = concat(
      [
        for k in sort(keys(local.secret_env)) : {
          name      = k
          valueFrom = "${aws_secretsmanager_secret.main.arn}:${k}::${aws_secretsmanager_secret_version.main.version_id}"
        }
      ],
      local.database_secrets,
    )
    portMappings = [
      { containerPort = local.agent_port, protocol = "tcp" },
      { containerPort = local.game_port, protocol = "tcp" },
    ]
    mountPoints = [{ sourceVolume = "home", containerPath = "/home/player", readOnly = false }]
    healthCheck = {
      command     = ["CMD-SHELL", "curl -fsS http://localhost:${local.game_port}/healthz >/dev/null || exit 1"]
      interval    = 30
      timeout     = 5
      retries     = 3
      startPeriod = 60
    }
    # Reaps the processes the agent's commands leave behind.
    linuxParameters = { initProcessEnabled = true }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.main.name
        awslogs-region        = var.cluster.region
        awslogs-stream-prefix = "lab"
      }
    }
  }])
}

resource "aws_ecs_service" "main" {
  name             = local.name
  cluster          = var.cluster.arn
  task_definition  = aws_ecs_task_definition.main.arn
  platform_version = "LATEST"

  # One player, one home directory: the old task stops before the new one
  # mounts it.
  desired_count                      = 1
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  enable_execute_command = true
  propagate_tags         = "SERVICE"
  wait_for_steady_state  = true

  capacity_provider_strategy {
    capacity_provider = var.spot ? "FARGATE_SPOT" : "FARGATE"
    weight            = 1
  }

  network_configuration {
    subnets          = var.cluster.network.private_subnet_ids
    security_groups  = concat([aws_security_group.task.id], local.client_security_groups)
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.box.arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [aws_efs_mount_target.home]
}

# A warning, not a failure: a VPC with endpoints can reach AWS without
# egress, but Claude and npm are on the internet.
check "egress" {
  assert {
    condition     = var.cluster.network.internet_egress
    error_message = "The VPC has no internet egress. The agent can't reach Claude without it."
  }
}

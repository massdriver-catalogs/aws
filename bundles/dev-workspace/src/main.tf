locals {
  name = var.md_metadata.name_prefix

  cpu    = tonumber(split("/", var.size)[0])
  memory = tonumber(split("/", var.size)[1])

  # Bundle secrets are not OpenTofu variables. The provisioner writes them here.
  app_secrets = try(jsondecode(file("/massdriver/secrets.json")), {})

  secret_env = merge(
    { for k in ["ANTHROPIC_API_KEY", "GH_TOKEN"] : k => local.app_secrets[k] if lookup(local.app_secrets, k, "") != "" },
    { MASSDRIVER_API_KEY = massdriver_service_account.workspace.token },
  )

  environment = {
    MASSDRIVER_URL             = var.massdriver.url
    MASSDRIVER_ORGANIZATION_ID = var.massdriver.organization_id
    WORKSPACE_GIT_NAME         = var.git_name
    WORKSPACE_GIT_EMAIL        = var.git_email
    WORKSPACE_MISE_TOOLS       = join(" ", var.mise_tools)
  }

  # A digest rather than a tag, so a restarted task runs the image that was
  # deployed, not whatever was pushed since.
  image = "${var.codebase.registry.url}@${data.aws_ecr_image.workspace.image_digest}"
}

data "aws_ecr_image" "workspace" {
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
  description             = "Keys of the ${local.name} workspace"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "main" {
  secret_id     = aws_secretsmanager_secret.main.id
  secret_string = jsonencode(local.secret_env)
}

resource "aws_security_group" "task" {
  name        = local.name
  description = "The ${local.name} workspace"
  vpc_id      = var.cluster.network.id
}

# Installs, git, Claude and Massdriver are all on the internet.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.task.id
  description       = "Outbound through the VPC egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# The Developer VPN forwards the laptop's traffic from inside the VPC, so the
# VPC's range is what lets it reach a dev server here.
resource "aws_vpc_security_group_ingress_rule" "vpc" {
  for_each = toset([for p in var.vpn_ports : tostring(p)])

  security_group_id = aws_security_group.task.id
  description       = "Dev server on ${each.value} from the VPC"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.value)
  to_port           = tonumber(each.value)
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
    name        = "workspace"
    image       = local.image
    essential   = true
    environment = [for k in sort(keys(local.environment)) : { name = k, value = local.environment[k] }]
    # The version id makes a new task definition when a secret changes, so
    # the task restarts with it.
    secrets = [
      for k in sort(keys(local.secret_env)) : {
        name      = k
        valueFrom = "${aws_secretsmanager_secret.main.arn}:${k}::${aws_secretsmanager_secret_version.main.version_id}"
      }
    ]
    mountPoints = [{ sourceVolume = "home", containerPath = "/home/dev", readOnly = false }]
    # Reaps the processes developers leave behind in ECS Exec sessions.
    linuxParameters = { initProcessEnabled = true }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.main.name
        awslogs-region        = var.cluster.region
        awslogs-stream-prefix = "workspace"
      }
    }
  }])
}

resource "aws_ecs_service" "main" {
  name             = local.name
  cluster          = var.cluster.arn
  task_definition  = aws_ecs_task_definition.main.arn
  platform_version = "LATEST"

  # One developer, one home directory: the old task stops before the new one
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
    security_groups  = [aws_security_group.task.id]
    assign_public_ip = false
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  depends_on = [
    massdriver_service_account_group_membership.workspace,
    aws_efs_mount_target.home,
  ]
}

# A warning, not a failure: a VPC with endpoints can reach AWS without
# egress, but Claude, Massdriver and package registries are on the internet.
check "egress" {
  assert {
    condition     = var.cluster.network.internet_egress
    error_message = "The VPC has no internet egress. The workspace can't reach Claude, Massdriver or package registries without it."
  }
}

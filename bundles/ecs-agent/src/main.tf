locals {
  name = var.md_metadata.name_prefix

  cpu    = tonumber(split("/", var.size)[0])
  memory = tonumber(split("/", var.size)[1])

  # Bundle secrets are not OpenTofu variables. The provisioner writes them here.
  app_secrets = try(jsondecode(file("/massdriver/secrets.json")), {})
  # The secret may arrive as a JSON string or as an object.
  mcp_env = try(jsondecode(local.app_secrets.MCP_ENV), lookup(local.app_secrets, "MCP_ENV", {}))

  # The agent's own keys come last, so an MCP secret can't replace them.
  secret_env = merge(
    { for k, v in local.mcp_env : k => tostring(v) },
    {
      ANTHROPIC_API_KEY  = lookup(local.app_secrets, "ANTHROPIC_API_KEY", "")
      MASSDRIVER_API_KEY = massdriver_service_account.agent.token
    },
  )

  # Claude Code expands ${VAR} in an MCP config from the container's
  # environment, so secrets stay out of the task definition.
  massdriver_mcp = {
    type    = "stdio"
    command = "mcp-server"
    args    = []
    env = {
      MASSDRIVER_API_KEY         = "$${MASSDRIVER_API_KEY}"
      MASSDRIVER_ORGANIZATION_ID = "$${MASSDRIVER_ORGANIZATION_ID}"
      MASSDRIVER_URL             = "$${MASSDRIVER_URL}"
    }
  }

  # Local and remote servers have different fields, which a conditional
  # can't return as one type; JSON round-trips them.
  extra_mcp = {
    for s in var.mcp_servers : s.name => jsondecode(s.transport == "stdio" ? jsonencode({
      type    = "stdio"
      command = s.command
      args    = coalesce(s.args, [])
      env     = { for e in coalesce(s.env, []) : e.name => e.value }
      }) : jsonencode({
      type    = s.transport
      url     = s.url
      headers = { for h in coalesce(s.headers, []) : h.name => h.value }
    }))
  }

  mcp_config = jsonencode({ mcpServers = merge(local.extra_mcp, { massdriver = local.massdriver_mcp }) })

  environment = {
    AGENT_NAME                 = var.service_account_name
    AGENT_GOAL                 = var.goal
    AGENT_MODEL                = var.model
    AGENT_EFFORT               = var.effort
    AGENT_INTERVAL_SECONDS     = tostring(var.interval_minutes * 60)
    AGENT_BUDGET_USD           = tostring(var.budget_per_run_usd)
    AGENT_MCP_CONFIG           = local.mcp_config
    AGENT_MISE_TOOLS           = join(" ", var.mise_tools)
    MASSDRIVER_URL             = var.massdriver.url
    MASSDRIVER_ORGANIZATION_ID = var.massdriver.organization_id
  }

  pull_policies = var.codebase == null ? {} : { for p in var.codebase.registry.policies : "codebase-${p.name}" => p.arn if p.name == "pull" }
}

resource "aws_kms_key" "main" {
  description             = "Secrets and transcripts of ${local.name}"
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

# Transcripts hold whatever the agent read, which can include other
# instances' configuration, so they're encrypted with the bundle's own key.
resource "aws_cloudwatch_log_group" "main" {
  name              = "/ecs/${local.name}"
  retention_in_days = var.log_retention_days
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_secretsmanager_secret" "main" {
  name_prefix             = "${local.name}-"
  description             = "Keys of the ${local.name} agent"
  kms_key_id              = aws_kms_key.main.arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "main" {
  secret_id     = aws_secretsmanager_secret.main.id
  secret_string = jsonencode(local.secret_env)
}

resource "aws_security_group" "task" {
  name        = local.name
  description = "The ${local.name} agent"
  vpc_id      = var.cluster.network.id
}

# The agent calls Claude, Massdriver and whatever its MCP servers and tools
# reach, through the VPC's egress. Nothing connects to it.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.task.id
  description       = "Outbound through the VPC egress"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
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

  container_definitions = jsonencode([{
    name        = "agent"
    image       = var.image_uri
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
    # Lets ECS Exec sessions and signals reach the loop's child processes.
    linuxParameters = { initProcessEnabled = true }
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.main.name
        awslogs-region        = var.cluster.region
        awslogs-stream-prefix = "agent"
      }
    }
  }])

  lifecycle {
    precondition {
      condition     = var.image_uri != ""
      error_message = "Set Agent image. Build it from this bundle's image/ directory and push it to a registry the cluster can pull from; see the README."
    }
    precondition {
      condition     = lookup(local.app_secrets, "ANTHROPIC_API_KEY", "") != ""
      error_message = "Set the ANTHROPIC_API_KEY secret on this instance."
    }
    precondition {
      condition     = length(var.mcp_servers) == length(distinct([for s in var.mcp_servers : s.name])) && !contains([for s in var.mcp_servers : s.name], "massdriver")
      error_message = "Each of More MCP servers needs its own name, and massdriver is taken."
    }
    precondition {
      condition     = alltrue([for s in var.mcp_servers : length(trimspace(coalesce(s.transport == "stdio" ? s.command : s.url, " "))) > 0])
      error_message = "A local MCP server needs a Command, and a remote one needs a URL."
    }
    precondition {
      condition     = alltrue([for k in keys(local.mcp_env) : can(regex("^[A-Za-z_][A-Za-z0-9_]*$", k))])
      error_message = "The keys of the MCP_ENV secret must be environment variable names: letters, digits and underscores."
    }
  }
}

resource "aws_ecs_service" "main" {
  name             = local.name
  cluster          = var.cluster.arn
  task_definition  = aws_ecs_task_definition.main.arn
  platform_version = "LATEST"

  # Two copies would work the same goal and act twice, so the old task stops
  # before the new one starts.
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

  # The first run needs the groups' permissions, or it finds nothing to work on.
  depends_on = [massdriver_service_account_group_membership.agent]
}

# A warning, not a failure: a VPC with endpoints can reach AWS without
# egress, but Claude and Massdriver are on the internet.
check "egress" {
  assert {
    condition     = var.cluster.network.internet_egress
    error_message = "The VPC has no internet egress. The agent can't reach Claude or Massdriver without it."
  }
}

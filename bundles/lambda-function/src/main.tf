locals {
  name      = var.md_metadata.name_prefix
  region    = var.api.region
  has_image = var.image_uri != ""

  # Databases and caches only listen inside the VPC. Functions that don't use
  # them stay out of it and keep reaching AWS APIs without the VPC's egress.
  in_vpc          = var.postgres != null || var.mariadb != null || var.cache != null
  private_subnets = var.network == null ? [] : [for s in var.network.subnets : s.id if s.tier == "private"]

  client_security_groups = compact([
    try(var.postgres.client_security_group_id, null),
    try(var.mariadb.client_security_group_id, null),
    try(var.cache.client_security_group_id, null),
  ])

  connected_regions = {
    for k, v in {
      network  = try(var.network.region, null)
      codebase = try(var.codebase.registry.region, null)
      postgres = try(var.postgres.region, null)
      mariadb  = try(var.mariadb.region, null)
      cache    = try(var.cache.region, null)
      table    = try(var.table.region, null)
      bucket   = try(var.bucket.region, null)
      queue    = try(var.queue.region, null)
    } : k => v if v != null
  }
  wrong_region = [for k, v in local.connected_regions : "${k} (${v})" if v != local.region]

  # A choice that no longer exists on the connected resource falls back to the
  # default instead of failing, so swapping the resource doesn't block deploys.
  codebase_policy = var.codebase == null ? null : concat([for p in var.codebase.registry.policies : p if p.name == "pull"], var.codebase.registry.policies)[0]
  table_policy    = var.table == null ? null : concat([for p in var.table.policies : p if p.name == coalesce(var.table_access, "read-write")], [for p in var.table.policies : p if p.name == "read-write"], var.table.policies)[0]
  bucket_policy   = var.bucket == null ? null : concat([for p in var.bucket.policies : p if p.name == coalesce(var.bucket_access, "read-write")], [for p in var.bucket.policies : p if p.name == "read-write"], var.bucket.policies)[0]
  queue_policy    = var.queue == null ? null : concat([for p in var.queue.policies : p if p.name == coalesce(var.queue_access, "send")], [for p in var.queue.policies : p if p.name == "send"], var.queue.policies)[0]

  database_policies = merge(
    var.postgres == null ? {} : { for p in var.postgres.policies : "postgres-${p.name}" => p.arn },
    var.mariadb == null ? {} : { for p in var.mariadb.policies : "mariadb-${p.name}" => p.arn },
  )

  consume_queue = var.consume_queue && var.queue != null && try(local.queue_policy.name, "") == "consume"

  # Shared with the ECS service bundle, so an app moves between runtimes
  # without changing how it reads its configuration.
  reserved_env = [
    "DATABASE_URL", "PGHOST", "PGPORT", "PGDATABASE", "PGUSER", "PGPASSWORD",
    "MYSQL_URL", "MYSQL_HOST", "MYSQL_PORT", "MYSQL_DATABASE", "MYSQL_USER", "MYSQL_PASSWORD",
    "REDIS_URL", "TABLE_NAME", "BUCKET_NAME", "QUEUE_URL",
  ]
  reserved_in_use = [for e in var.environment : e.name if contains(local.reserved_env, e.name)]

  environment = merge(
    { for e in var.environment : e.name => e.value },
    var.postgres == null ? {} : {
      DATABASE_URL = "postgres://${urlencode(var.postgres.username)}:${urlencode(var.postgres.password)}@${var.postgres.hostname}:${var.postgres.port}/${var.postgres.database}"
      PGHOST       = var.postgres.hostname
      PGPORT       = tostring(var.postgres.port)
      PGDATABASE   = var.postgres.database
      PGUSER       = var.postgres.username
      PGPASSWORD   = var.postgres.password
    },
    var.mariadb == null ? {} : {
      MYSQL_URL      = "mysql://${urlencode(var.mariadb.username)}:${urlencode(var.mariadb.password)}@${var.mariadb.hostname}:${var.mariadb.port}/${var.mariadb.database}"
      MYSQL_HOST     = var.mariadb.hostname
      MYSQL_PORT     = tostring(var.mariadb.port)
      MYSQL_DATABASE = var.mariadb.database
      MYSQL_USER     = var.mariadb.username
      MYSQL_PASSWORD = var.mariadb.password
    },
    var.cache == null ? {} : { REDIS_URL = "rediss://${var.cache.hostname}:${var.cache.port}" },
    var.table == null ? {} : { TABLE_NAME = var.table.name },
    var.bucket == null ? {} : { BUCKET_NAME = var.bucket.name },
    var.queue == null ? {} : { QUEUE_URL = var.queue.url },
  )
}

data "archive_file" "placeholder" {
  type        = "zip"
  output_path = "${path.module}/placeholder.zip"

  source {
    filename = "handler.py"
    content  = file("${path.module}/placeholder/handler.py")
  }
}

resource "aws_cloudwatch_log_group" "function" {
  name              = "/aws/lambda/${local.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_iam_role" "function" {
  name = local.name
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "logs" {
  name = "write-logs"
  role = aws_iam_role.function.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.function.arn}:*"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "xray" {
  role       = aws_iam_role.function.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

resource "aws_iam_role_policy_attachment" "vpc" {
  count      = local.in_vpc ? 1 : 0
  role       = aws_iam_role.function.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy_attachment" "codebase" {
  count      = var.codebase != null ? 1 : 0
  role       = aws_iam_role.function.name
  policy_arn = local.codebase_policy.arn
}

resource "aws_iam_role_policy_attachment" "databases" {
  for_each   = local.database_policies
  role       = aws_iam_role.function.name
  policy_arn = each.value
}

resource "aws_iam_role_policy_attachment" "table" {
  count      = var.table != null ? 1 : 0
  role       = aws_iam_role.function.name
  policy_arn = local.table_policy.arn
}

resource "aws_iam_role_policy_attachment" "bucket" {
  count      = var.bucket != null ? 1 : 0
  role       = aws_iam_role.function.name
  policy_arn = local.bucket_policy.arn
}

resource "aws_iam_role_policy_attachment" "queue" {
  count      = var.queue != null ? 1 : 0
  role       = aws_iam_role.function.name
  policy_arn = local.queue_policy.arn
}

resource "aws_security_group" "function" {
  count       = local.in_vpc ? 1 : 0
  name        = local.name
  description = "Lambda function ${local.name}: outbound only"
  vpc_id      = try(var.network.id, null)

  egress {
    description = "Databases, cache, AWS APIs and the internet through the VPC egress"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    precondition {
      condition     = !local.in_vpc || var.network != null
      error_message = "A database or cache is connected, and they are only reachable inside the VPC. Connect the VPC (aws-vpc) to this function too."
    }
  }
}

resource "aws_lambda_function" "main" {
  function_name = local.name
  role          = aws_iam_role.function.arn
  architectures = ["arm64"]
  memory_size   = var.memory_mb
  timeout       = var.timeout_seconds

  package_type     = local.has_image ? "Image" : "Zip"
  image_uri        = local.has_image ? var.image_uri : null
  runtime          = local.has_image ? null : "python3.13"
  handler          = local.has_image ? null : "handler.handler"
  filename         = local.has_image ? null : data.archive_file.placeholder.output_path
  source_code_hash = local.has_image ? null : data.archive_file.placeholder.output_base64sha256

  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.function.name
  }

  tracing_config {
    mode = "Active"
  }

  dynamic "vpc_config" {
    for_each = local.in_vpc ? [1] : []
    content {
      subnet_ids         = local.private_subnets
      security_group_ids = concat([aws_security_group.function[0].id], local.client_security_groups)
    }
  }

  dynamic "environment" {
    for_each = length(local.environment) > 0 ? [1] : []
    content {
      variables = local.environment
    }
  }

  lifecycle {
    precondition {
      condition     = !local.in_vpc || length(local.private_subnets) > 0
      error_message = "The connected VPC has no private subnets to run the function in."
    }
    precondition {
      condition     = length(local.wrong_region) == 0
      error_message = "This function runs in ${local.region}, the HTTP API's region, but these connected resources are elsewhere: ${join(", ", local.wrong_region)}. Connect ones from ${local.region}."
    }
    precondition {
      condition     = length(local.reserved_in_use) == 0
      error_message = "These environment variables are set from connected resources and can't be set by hand: ${join(", ", local.reserved_in_use)}. Remove them from Environment variables."
    }
    precondition {
      condition     = !var.consume_queue || var.queue != null
      error_message = "Consume from the queue is on, but no queue is connected. Connect an SQS queue or turn it off."
    }
    precondition {
      condition     = !var.consume_queue || var.queue == null || local.consume_queue
      error_message = "Consume from the queue is on, but Queue access is \"${try(local.queue_policy.name, "")}\". Set Queue access to consume."
    }
  }

  depends_on = [
    aws_iam_role_policy.logs,
    aws_iam_role_policy_attachment.vpc,
    aws_iam_role_policy_attachment.codebase,
  ]
}

check "vpc_egress" {
  assert {
    condition     = !local.in_vpc || var.network == null || var.network.internet_egress || (var.table == null && var.bucket == null && var.queue == null)
    error_message = "The function runs in the VPC to reach its database or cache, but the VPC has no internet egress, so calls to DynamoDB, S3 or SQS will time out unless the VPC has endpoints for them."
  }
}

resource "aws_apigatewayv2_integration" "main" {
  api_id                 = var.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.main.invoke_arn
  payload_format_version = "2.0"
  timeout_milliseconds   = 30000
}

resource "aws_apigatewayv2_route" "main" {
  for_each  = toset(var.routes)
  api_id    = var.api.id
  route_key = each.value
  target    = "integrations/${aws_apigatewayv2_integration.main.id}"
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowInvokeFromApi"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.main.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${var.api.execution_arn}/*/*"

  # Swapping the placeholder for an image replaces the function, and AWS drops
  # its permissions with it.
  lifecycle {
    replace_triggered_by = [aws_lambda_function.main]
  }
}

resource "aws_lambda_event_source_mapping" "queue" {
  count            = local.consume_queue ? 1 : 0
  event_source_arn = var.queue.arn
  function_name    = aws_lambda_function.main.arn
  batch_size       = 10

  depends_on = [aws_iam_role_policy_attachment.queue]
}

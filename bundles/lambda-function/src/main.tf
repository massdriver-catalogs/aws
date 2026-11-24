locals {
  name      = var.md_metadata.name_prefix
  region    = var.api.region
  has_image = var.image_uri != ""

  # An app running on this bundle declares its own databases, caches and
  # stores. The bundle names each one's type; the connection carries its data.
  runtime_dependencies = ["aws_authentication", "api", "codebase", "registry", "network"]
  connected            = try(jsondecode(file("/massdriver/dependencies.json")), {})
  app_dependencies = {
    for k, d in try(yamldecode(file("/massdriver/bundle/massdriver.yaml")).dependencies, {}) :
    k => { type = split("@", d.resource_type)[0], value = local.connected[k] }
    if !contains(local.runtime_dependencies, k) && try(local.connected[k], null) != null
  }

  # What the function gets from each standard type. Other types pass through
  # only as the app's environment variables.
  joins_security_group = ["aws-postgres", "aws-mariadb", "aws-valkey"]
  gets_policies        = ["aws-postgres", "aws-mariadb", "aws-dynamodb-table", "aws-s3-bucket", "aws-sqs-queue"]

  client_security_groups = [for d in values(local.app_dependencies) : d.value.client_security_group_id if contains(local.joins_security_group, d.type)]
  app_policies = merge([
    for k, d in local.app_dependencies : { for p in d.value.policies : "${k}-${p.name}" => p.arn } if contains(local.gets_policies, d.type)
  ]...)

  # Databases and caches only listen inside the VPC. Functions that don't use
  # them stay out of it and keep reaching AWS APIs without the VPC's egress.
  in_vpc          = length(local.client_security_groups) > 0
  private_subnets = var.network == null ? [] : [for s in var.network.subnets : s.id if s.tier == "private"]

  connected_regions = {
    for k, v in merge(
      {
        network  = try(var.network.region, null)
        codebase = try(var.codebase.registry.region, null)
        registry = try(var.registry.region, null)
      },
      { for k, d in local.app_dependencies : k => try(d.value.region, null) },
    ) : k => v if v != null
  }
  wrong_region = [for k, v in local.connected_regions : "${k} (${v})" if v != local.region]

  codebase_policy = var.codebase == null ? null : concat([for p in var.codebase.registry.policies : p if p.name == "pull"], var.codebase.registry.policies)[0]
  registry_policy = var.registry == null ? null : concat([for p in var.registry.policies : p if p.name == "pull"], var.registry.policies)[0]

  queue_arns    = [for d in values(local.app_dependencies) : d.value.arn if d.type == "aws-sqs-queue"]
  consume_queue = var.consume_queue && length(local.queue_arns) == 1

  # An application running on this bundle declares its own variables in its
  # app block; Massdriver renders them here before the step runs.
  environment = merge(
    try(jsondecode(file("/massdriver/envs.json")), {}),
    { for e in var.environment : e.name => e.value },
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

resource "aws_iam_role_policy_attachment" "registry" {
  count      = var.registry != null ? 1 : 0
  role       = aws_iam_role.function.name
  policy_arn = local.registry_policy.arn
}

resource "aws_iam_role_policy_attachment" "app" {
  for_each   = local.app_policies
  role       = aws_iam_role.function.name
  policy_arn = each.value
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
      condition     = !var.consume_queue || length(local.queue_arns) == 1
      error_message = "Consume from the queue is on, so the app needs exactly one SQS queue connected; it has ${length(local.queue_arns)}."
    }
  }

  depends_on = [
    aws_iam_role_policy.logs,
    aws_iam_role_policy_attachment.vpc,
    aws_iam_role_policy_attachment.codebase,
    aws_iam_role_policy_attachment.registry,
  ]
}

check "vpc_egress" {
  assert {
    condition     = !local.in_vpc || var.network == null || var.network.internet_egress || alltrue([for d in values(local.app_dependencies) : contains(local.joins_security_group, d.type)])
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
  for_each         = local.consume_queue ? { queue = local.queue_arns[0] } : {}
  event_source_arn = each.value
  function_name    = aws_lambda_function.main.arn
  batch_size       = 10

  depends_on = [aws_iam_role_policy_attachment.app]
}

moved {
  from = aws_lambda_event_source_mapping.queue[0]
  to   = aws_lambda_event_source_mapping.queue["queue"]
}

# These attached the same policies the app attachments now hold. Destroying
# them would detach those policies out from under the new attachments.
removed {
  from = aws_iam_role_policy_attachment.databases
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.table
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.bucket
  lifecycle {
    destroy = false
  }
}

removed {
  from = aws_iam_role_policy_attachment.queue
  lifecycle {
    destroy = false
  }
}

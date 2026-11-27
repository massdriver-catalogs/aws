terraform {
  required_version = ">= 1.7"

  required_providers {
    massdriver = {
      source  = "massdriver-cloud/massdriver"
      version = "~> 2.5"
    }
  }
}

provider "massdriver" {}

variable "aws_role" {
  description = "The IAM role Massdriver deploys with, from the aws-iam-role credential's instructions. deploy.sh role makes it."
  type = object({
    arn         = string
    token_level = optional(string, "organization")
  })
}

variable "existing_bundle_repositories" {
  description = "Bundle repositories already in the organization. They're adopted instead of created."
  type        = list(string)
  default     = []
}

locals {
  projects = {
    # Shared by every Fauxroku app, like Heroku's common runtime: one VPC, one
    # load balancer and one wildcard certificate instead of one per customer.
    platform = {
      name        = "Platform"
      description = "The network, DNS zone and container cluster every Fauxroku app runs on."
      stages      = { main = "Main" }
      components = {
        network = { bundle = "vpc", name = "Network" }
        dns     = { bundle = "dns-zone", name = "DNS Zone" }
        cluster = { bundle = "ecs-cluster", name = "Router" }
      }
      links = [
        "network.network -> cluster.network",
        "dns.zone -> cluster.dns",
      ]
    }

    # Rocketsled forks the template once per customer environment. The
    # template itself is never deployed.
    fauxroku = {
      name        = "Fauxroku"
      description = "Heroku-style apps: web and worker dynos, with Postgres and Key-Value Store add-ons. One environment per customer environment, forked from the template by Rocketsled."
      stages      = { template = "Template" }
      components = {
        web    = { bundle = "fauxroku-web", name = "Web Dynos" }
        worker = { bundle = "fauxroku-worker", name = "Worker Dynos" }
        db     = { bundle = "postgres", name = "Postgres" }
        cache  = { bundle = "valkey", name = "Key-Value Store" }
      }
      links = [
        "db.database -> web.database",
        "db.database -> worker.database",
        "cache.cache -> web.cache",
        "cache.cache -> worker.cache",
      ]
    }

    # Nothing shared: every environment has its own API, so it has its own URL
    # and costs nothing while nobody calls it.
    fauxcel = {
      name        = "Fauxcel"
      description = "Vercel-style sites: serverless functions behind an HTTPS endpoint, with KV and Blob storage. One environment per customer environment, forked from the template by Rocketsled."
      stages      = { template = "Template" }
      components = {
        api  = { bundle = "http-api", name = "Endpoint" }
        app  = { bundle = "fauxcel-app", name = "Functions" }
        kv   = { bundle = "dynamodb-table", name = "KV" }
        blob = { bundle = "s3-bucket", name = "Blob" }
      }
      links = [
        "api.api -> app.api",
        "kv.table -> app.kv",
        "blob.bucket -> app.blob",
      ]
    }
  }

  environments = merge([
    for p, project in local.projects : {
      for s, name in project.stages : "${p}-${s}" => { project = p, stage = s, name = name }
    }
  ]...)

  components = merge([
    for p, project in local.projects : {
      for c, component in project.components : "${p}-${c}" => merge(component, { project = p, identifier = c })
    }
  ]...)

  links = merge([
    for p, project in local.projects : {
      for l in project.links : "${p}:${l}" => {
        from       = "${p}-${split(".", trimspace(split("->", l)[0]))[0]}"
        from_field = split(".", trimspace(split("->", l)[0]))[1]
        to         = "${p}-${split(".", trimspace(split("->", l)[1]))[0]}"
        to_field   = split(".", trimspace(split("->", l)[1]))[1]
      }
    }
  ]...)

  # Runtimes are granted too: an app bundle is published on top of its runtime.
  bundle_access = merge(
    { for b in ["vpc", "dns-zone", "ecs-cluster"] : b => "platform" },
    { for b in ["ecs-service", "postgres", "valkey", "fauxroku-web", "fauxroku-worker"] : b => "fauxroku" },
    { for b in ["http-api", "lambda-function", "dynamodb-table", "s3-bucket", "fauxcel-app"] : b => "fauxcel" },
  )

  # What a PaaS's Rocketsled server may do in its own project: fork the
  # template into customer environments, deploy them and remove them.
  server_actions = [
    "project:view",
    "environment:create",
    "environment:update",
    "environment:configure",
    "environment:deploy",
    "environment:decommission",
    "environment:delete",
    "instance:configure",
    "instance:plan",
    "instance:deploy",
    "instance:decommission",
  ]

  paas = {
    fauxroku = "Fauxroku"
    fauxcel  = "Fauxcel"
  }
}

resource "massdriver_project" "this" {
  for_each = local.projects

  identifier  = each.key
  name        = each.value.name
  description = each.value.description
}

import {
  for_each = toset([for name in var.existing_bundle_repositories : name if contains(keys(local.bundle_access), name)])
  to       = massdriver_oci_repository.bundle[each.key]
  id       = each.key
}

resource "massdriver_oci_repository" "bundle" {
  for_each = local.bundle_access

  name          = each.key
  artifact_type = "BUNDLE"
}

resource "massdriver_oci_repository_grant" "bundle" {
  for_each = local.bundle_access

  repository_id        = massdriver_oci_repository.bundle[each.key].id
  recipient_conditions = jsonencode({ "md-project" = [each.value] })
}

resource "massdriver_environment" "this" {
  for_each = local.environments

  project_id = massdriver_project.this[each.value.project].id
  identifier = each.value.stage
  name       = each.value.name
}

resource "massdriver_component" "this" {
  for_each = local.components

  project_id  = massdriver_project.this[each.value.project].id
  identifier  = each.value.identifier
  name        = each.value.name
  bundle_name = each.value.bundle

  depends_on = [massdriver_oci_repository_grant.bundle]
}

resource "massdriver_component_link" "this" {
  for_each = local.links

  from_component_id = massdriver_component.this[each.value.from].id
  from_field        = each.value.from_field
  to_component_id   = massdriver_component.this[each.value.to].id
  to_field          = each.value.to_field
}

resource "massdriver_imported_resource" "aws" {
  name          = "AWS"
  resource_type = "aws-iam-role"
  resource      = jsonencode(var.aws_role)

  # The API reads the type back with its version (aws-iam-role@0.0.0), which
  # would otherwise replace the credential, and unset every default, on each apply.
  lifecycle {
    ignore_changes = [resource_type]
  }
}

# Every customer environment is new, so the credential is open to all of them.
resource "massdriver_resource_grant" "aws" {
  resource_id          = massdriver_imported_resource.aws.id
  recipient_conditions = "*"
}

resource "massdriver_group" "server" {
  for_each = local.paas

  name        = "${each.value} Servers"
  description = "The ${each.value} Rocketsled server: forks, deploys and removes environments in the ${each.key} project, and nothing else."
}

resource "massdriver_group_policy" "server" {
  for_each = local.paas

  group_id   = massdriver_group.server[each.key].id
  effect     = "ALLOW"
  actions    = local.server_actions
  conditions = jsonencode({ "md-project" = [each.key] })
}

# Forking copies the template's defaults, and each one must be viewable.
resource "massdriver_group_policy" "server_read" {
  for_each = local.paas

  group_id   = massdriver_group.server[each.key].id
  effect     = "ALLOW"
  actions    = ["resource:view"]
  conditions = "*"
}

resource "massdriver_service_account" "server" {
  for_each = local.paas

  name                     = "${each.value} Server"
  description              = "The ${each.value} Rocketsled server."
  token_expiration_minutes = 60 * 24 * 365
}

resource "massdriver_service_account_group_membership" "server" {
  for_each = local.paas

  group_id           = massdriver_group.server[each.key].id
  service_account_id = massdriver_service_account.server[each.key].id
}

output "environments" {
  value = { for k, e in local.environments : k => { project = e.project, stage = e.stage } }
}

output "aws_credential" {
  value = massdriver_imported_resource.aws.id
}

output "server_api_keys" {
  value     = { for k, s in massdriver_service_account.server : k => s.token }
  sensitive = true
}

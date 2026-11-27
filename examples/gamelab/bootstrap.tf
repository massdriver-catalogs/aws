terraform {
  required_version = ">= 1.7"

  required_providers {
    massdriver = {
      source  = "massdriver-cloud/massdriver"
      version = "~> 2.5"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
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
  description = "Bundle repositories already in the organization, e.g. from the catalog's publish workflow. They're adopted instead of created."
  type        = list(string)
  default     = []
}

locals {
  projects = {
    platform = {
      name        = "Platform"
      description = "The network, DNS zone and container cluster Gamelab and every lab share."
      stages      = { main = "Main" }
      components = {
        network = { bundle = "vpc", name = "Network" }
        dns     = { bundle = "dns-zone", name = "DNS Zone" }
        cluster = { bundle = "ecs-cluster", name = "ECS Cluster" }
      }
      links = [
        "network.network -> cluster.network",
        "dns.zone -> cluster.dns",
      ]
    }

    # The cluster stays undeployed; the server runs on the platform's cluster,
    # its environment default. Source Repository stays undeployed until the
    # server moves to its own GitHub repository; until then deploy.sh pushes
    # its image straight to the registry. Lab Power is the server's permission
    # to put lab boxes to sleep and wake them.
    gamelab = {
      name        = "Gamelab"
      description = "The Gamelab server: the one public site, where parents make labs and players use them."
      stages      = { main = "Main" }
      components = {
        registry = { bundle = "ecr-repository", name = "Image Repository" }
        codebase = { bundle = "codebase", name = "Codebase" }
        cluster  = { bundle = "ecs-cluster", name = "ECS Cluster" }
        power    = { bundle = "ecs-scaling-policy", name = "Lab Power" }
        app      = { bundle = "gamelab-server", name = "Gamelab Server" }
      }
      links = [
        "registry.repository -> codebase.registry",
        "codebase.codebase -> app.codebase",
        "cluster.cluster -> app.cluster",
        "cluster.cluster -> power.cluster",
        "power.policy -> app.lab_power",
      ]
    }

    # The template builds the lab image once: its registry and codebase are
    # deployed there and become every lab's default codebase. Labs leave
    # theirs undeployed, like the cluster, which comes from the platform.
    # Saves & Scores deploys only in labs whose parent picked it.
    labs = {
      name        = "Labs"
      description = "One environment per player, forked from the template by the Gamelab server: a lab box with a game-making helper, and optional saves and high scores."
      stages      = { template = "Template" }
      components = {
        registry = { bundle = "ecr-repository", name = "Lab Image Repository" }
        codebase = { bundle = "codebase", name = "Lab Codebase" }
        cluster  = { bundle = "ecs-cluster", name = "ECS Cluster" }
        box      = { bundle = "lab-box", name = "Lab Box" }
        gamedata = { bundle = "dynamodb-table", name = "Saves & Scores" }
      }
      links = [
        "registry.repository -> codebase.registry",
        "codebase.codebase -> box.codebase",
        "cluster.cluster -> box.cluster",
        "gamedata.table -> box.gamedata",
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

  # Every catalog bundle is open to every project, except the lab box, which
  # belongs in labs, and the server, which belongs in gamelab.
  bundle_access = merge(
    # Only what Gamelab runs, so its organization holds nothing else. Postgres
    # and Valkey no longer run anywhere; dropping them deletes their published
    # releases from the organization, so that waits for someone to decide.
    { for b in ["vpc", "dns-zone", "ecs-cluster", "ecr-repository", "codebase", "ecs-service", "dynamodb-table", "postgres", "valkey"] : b => "*" },
    { (yamldecode(file("${path.module}/applications/gamelab/bundle/massdriver.yaml")).name) = "gamelab" },
    { "ecs-scaling-policy" = "gamelab" },
    { "lab-box" = "labs" },
  )

  # What the server may do to labs: make them, deploy them and remove them.
  lab_actions = [
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
    "stash:view",
    "stash:write",
    "stash:export",
  ]
}

# The server records each lab's plan and the player's age on its environment,
# where policies, reports and anyone in Massdriver can see them.
resource "massdriver_custom_attribute" "lab_plan" {
  key    = "lab_plan"
  scope  = "ENVIRONMENT"
  values = ["small", "medium", "large"]
}

resource "massdriver_custom_attribute" "player_age" {
  key    = "player_age"
  scope  = "ENVIRONMENT"
  values = [for age in range(5, 18) : tostring(age)]
}

resource "massdriver_organization_settings" "this" {
  # Every bundle's access is granted below, so the lab box and the server stay with their own projects.
  grant_new_bundles_to_all_projects = false
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
  recipient_conditions = each.value == "*" ? "*" : jsonencode({ "md-project" = [each.value] })
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

# Every lab is a new environment, so the credential is open to all of them.
resource "massdriver_resource_grant" "aws" {
  resource_id          = massdriver_imported_resource.aws.id
  recipient_conditions = "*"
}

resource "massdriver_group" "admins" {
  name        = "Gamelab Admins"
  description = "The grown-ups who run Gamelab: everything, everywhere."
}

resource "massdriver_group_policy" "admins" {
  group_id   = massdriver_group.admins.id
  effect     = "ALLOW"
  actions    = ["*"]
  conditions = "*"
}

# The server's only way into Massdriver. It can read resources anywhere, since
# forking copies the template's defaults and each one must be viewable, and
# change nothing outside labs.
resource "massdriver_group" "servers" {
  name        = "Gamelab Servers"
  description = "The Gamelab server: makes, deploys and removes labs, and nothing else."
}

resource "massdriver_group_policy" "servers_labs" {
  group_id   = massdriver_group.servers.id
  effect     = "ALLOW"
  actions    = local.lab_actions
  conditions = jsonencode({ "md-project" = ["labs"] })
}

resource "massdriver_group_policy" "servers_read" {
  group_id   = massdriver_group.servers.id
  effect     = "ALLOW"
  actions    = ["resource:view"]
  conditions = "*"
}

resource "massdriver_service_account" "server" {
  name                     = "Gamelab Server"
  description              = "The Gamelab server. Makes, deploys and removes labs in the labs project."
  token_expiration_minutes = 60 * 24 * 365
}

resource "massdriver_service_account_group_membership" "server" {
  group_id           = massdriver_group.servers.id
  service_account_id = massdriver_service_account.server.id
}

resource "random_password" "sign_in" {
  length  = 20
  special = false
}

resource "random_password" "session" {
  length  = 48
  special = false
}

output "environments" {
  value = { for k, e in local.environments : k => { project = e.project, stage = e.stage } }
}

output "aws_credential" {
  value = massdriver_imported_resource.aws.id
}

output "server_api_key" {
  value     = massdriver_service_account.server.token
  sensitive = true
}

output "gamelab_password" {
  value     = random_password.sign_in.result
  sensitive = true
}

output "session_secret" {
  value     = random_password.session.result
  sensitive = true
}

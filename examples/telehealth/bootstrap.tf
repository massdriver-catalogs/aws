terraform {
  required_version = ">= 1.6"

  required_providers {
    massdriver = {
      source  = "massdriver-cloud/massdriver"
      version = "~> 2.4"
    }
  }
}

provider "massdriver" {}

variable "aws_accounts" {
  description = "IAM roles Massdriver deploys with, from the aws-iam-role credential's instructions. nonprod serves dev, staging and previews; prod serves prod. Use the same role for both to run everything in one account."
  type = object({
    nonprod = object({ arn = string, token_level = optional(string, "organization") })
    prod    = object({ arn = string, token_level = optional(string, "organization") })
  })
}

variable "existing_bundle_repositories" {
  description = "Bundle repositories already in the organization, e.g. from the catalog's publish workflow. They're adopted instead of created."
  type        = list(string)
  default     = []
}

variable "protect_prod" {
  description = "Prod environments need a second person to approve deploys and can't be decommissioned by accident."
  type        = bool
  default     = true
}

locals {
  stages = {
    dev     = { name = "Development", prod = false }
    staging = { name = "Staging", prod = false }
    prod    = { name = "Production", prod = true }
  }

  projects = {
    platform = {
      name        = "Platform"
      description = "The network, DNS zone and container cluster every app in an environment shares."
      team        = "platform"
      stages      = keys(local.stages)
      components = {
        network = { bundle = "vpc", name = "Network" }
        dns     = { bundle = "dns-zone", name = "DNS Zone" }
        cluster = { bundle = "ecs-cluster", name = "ECS Cluster" }
        oidc    = { bundle = "github-actions-oidc", name = "GitHub Actions OIDC" }
      }
      links = [
        "network.network -> cluster.network",
        "dns.zone -> cluster.dns",
      ]
    }

    apps = {
      name        = "Apps"
      description = "Onboards a new app: its GitHub repository, image registry and Massdriver project."
      team        = "platform"
      stages      = ["dev", "prod"]
      components = {
        registry = { bundle = "ecr-repository", name = "Image Repository" }
        project  = { bundle = "massdriver-project", name = "Massdriver Project" }
        repo     = { bundle = "github-repo", name = "Source Repository" }
        codebase = { bundle = "codebase", name = "Codebase" }
      }
      links = [
        "registry.repository -> repo.registry",
        "project.project -> repo.project",
        "registry.repository -> codebase.registry",
        "repo.repository -> codebase.repository",
        "project.project -> codebase.project",
      ]
    }

    visits = {
      name        = "Visits"
      description = "Patients find an open slot and book a video visit."
      team        = "patient-experience"
      stages      = keys(local.stages)
      components = {
        registry  = { bundle = "ecr-repository", name = "Image Repository" }
        api       = { bundle = "http-api", name = "Booking API" }
        slots     = { bundle = "dynamodb-table", name = "Slots" }
        reminders = { bundle = "sqs-queue", name = "Reminders Queue" }
        app       = { bundle = "tendwell-visits", name = "Visits" }
        notifier  = { bundle = "tendwell-visits", name = "Reminder Sender" }
      }
      links = [
        "registry.repository -> app.registry",
        "api.api -> app.api",
        "slots.table -> app.table",
        "reminders.queue -> app.queue",
        "registry.repository -> notifier.registry",
        "api.api -> notifier.api",
        "reminders.queue -> notifier.queue",
      ]
    }

    care = {
      name        = "Care"
      description = "The clinician portal: charts, encounters and visit notes."
      team        = "clinical"
      stages      = keys(local.stages)
      components = {
        registry  = { bundle = "ecr-repository", name = "Image Repository" }
        charts    = { bundle = "postgres", name = "Charts" }
        sessions  = { bundle = "valkey", name = "Sessions" }
        documents = { bundle = "s3-bucket", name = "Documents" }
        app       = { bundle = "tendwell-care", name = "Care" }
      }
      links = [
        "registry.repository -> app.registry",
        "charts.database -> app.postgres",
        "sessions.cache -> app.cache",
        "documents.bucket -> app.bucket",
      ]
    }

    billing = {
      name        = "Billing"
      description = "Files insurance claims for closed encounters. Came with the Clearpath acquisition."
      team        = "revenue"
      stages      = keys(local.stages)
      components = {
        registry = { bundle = "ecr-repository", name = "Image Repository" }
        ledger   = { bundle = "mariadb", name = "Claims Ledger" }
        claims   = { bundle = "s3-bucket", name = "Claim Files" }
        app      = { bundle = "tendwell-billing", name = "Billing" }
      }
      links = [
        "registry.repository -> app.registry",
        "ledger.database -> app.mariadb",
        "claims.bucket -> app.bucket",
      ]
    }
  }

  environments = merge([
    for p, project in local.projects : {
      for s in project.stages : "${p}-${s}" => { project = p, stage = s }
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

  # Anything that stores or carries patient details. Bookings name the patient,
  # so Visits counts as well as charts and claims.
  phi = [
    "visits-slots", "visits-reminders", "visits-app", "visits-notifier",
    "care-charts", "care-sessions", "care-documents", "care-app",
    "billing-ledger", "billing-claims", "billing-app",
  ]

  # Every catalog bundle is open to every project; each app's bundle only to its own.
  bundle_access = merge(
    { for f in fileset("${path.module}/../../bundles", "*/massdriver.yaml") : yamldecode(file("${path.module}/../../bundles/${f}")).name => "*" },
    { for app in ["visits", "care", "billing"] : yamldecode(file("${path.module}/applications/${app}/bundle/massdriver.yaml")).name => app },
  )

  teams = {
    patient-experience = { name = "Patient Experience", description = "Builds the booking experience patients use." }
    clinical           = { name = "Clinical", description = "Builds the tools clinicians chart and treat with." }
    revenue            = { name = "Revenue", description = "Runs billing and claims." }
  }

  team_actions = [
    "project:design",
    "project:update",
    "environment:create",
    "environment:update",
    "environment:configure",
    "environment:deploy",
    "environment:decommission",
    "instance:configure",
    "instance:plan",
    "instance:propose",
    "instance:deploy",
    "instance:decommission",
    "resource:export",
  ]

  read_actions = ["project:view", "resource:view", "repo:view", "repo:pull"]
}

resource "massdriver_project" "this" {
  for_each = local.projects

  identifier  = each.key
  name        = each.value.name
  description = each.value.description
  attributes  = { team = each.value.team }
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

  project_id              = massdriver_project.this[each.value.project].id
  identifier              = each.value.stage
  name                    = local.stages[each.value.stage].name
  separation_of_duty      = var.protect_prod && local.stages[each.value.stage].prod
  decommission_protection = var.protect_prod && local.stages[each.value.stage].prod
}

resource "massdriver_component" "this" {
  for_each = local.components

  project_id  = massdriver_project.this[each.value.project].id
  identifier  = each.value.identifier
  name        = each.value.name
  bundle_name = each.value.bundle
  attributes  = { data_classification = contains(local.phi, each.key) ? "phi" : "internal" }

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
  for_each = var.aws_accounts

  name          = "AWS ${each.key}"
  resource_type = "aws-iam-role"
  resource      = jsonencode(each.value)

  # The API reads the type back with its version (aws-iam-role@0.0.0), which
  # would otherwise replace the credential, and unset every default, on each apply.
  lifecycle {
    ignore_changes = [resource_type]
  }
}

resource "massdriver_resource_grant" "aws_nonprod" {
  resource_id          = massdriver_imported_resource.aws["nonprod"].id
  recipient_conditions = "*"
}

# Only prod environments can use the prod account's role.
resource "massdriver_resource_grant" "aws_prod" {
  resource_id          = massdriver_imported_resource.aws["prod"].id
  recipient_conditions = jsonencode({ "md-environment" = ["prod"] })
}

resource "massdriver_group" "platform" {
  name        = "Platform Engineering"
  description = "Owns the catalog, the platform project and app onboarding."
}

resource "massdriver_group_policy" "platform" {
  group_id   = massdriver_group.platform.id
  effect     = "ALLOW"
  actions    = ["*"]
  conditions = "*"
}

resource "massdriver_group" "team" {
  for_each = local.teams

  name        = each.value.name
  description = each.value.description
}

resource "massdriver_group_policy" "team_read" {
  for_each = local.teams

  group_id   = massdriver_group.team[each.key].id
  effect     = "ALLOW"
  actions    = local.read_actions
  conditions = "*"
}

resource "massdriver_group_policy" "team_own" {
  for_each = local.teams

  group_id   = massdriver_group.team[each.key].id
  effect     = "ALLOW"
  actions    = local.team_actions
  conditions = jsonencode({ "md-project" = [for p, project in local.projects : p if project.team == each.key] })
}

resource "massdriver_group" "security" {
  name        = "Security & Compliance"
  description = "Audits everything; deploys nothing."
}

resource "massdriver_group_policy" "security" {
  group_id   = massdriver_group.security.id
  effect     = "ALLOW"
  actions    = local.read_actions
  conditions = "*"
}

output "environments" {
  value = {
    for k, e in local.environments : k => {
      project    = e.project
      stage      = e.stage
      credential = massdriver_imported_resource.aws[local.stages[e.stage].prod ? "prod" : "nonprod"].id
    }
  }
}

output "one_account" {
  value = split(":", var.aws_accounts.nonprod.arn)[4] == split(":", var.aws_accounts.prod.arn)[4]
}

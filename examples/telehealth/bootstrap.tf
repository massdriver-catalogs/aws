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

variable "aws_accounts" {
  description = "IAM roles Massdriver deploys with, from the aws-iam-role credential's instructions. nonprod serves dev and the apps project's environments; prod serves prod. Use the same role for both to run everything in one account."
  type = object({
    nonprod = object({ arn = string, token_level = optional(string, "organization") })
    prod    = object({ arn = string, token_level = optional(string, "organization") })
  })
}

variable "organization_id" {
  description = "The organization's identifier, e.g. tendwell-health. bootstrap.sh sets it from mass whoami."
  type        = string
}

variable "massdriver_url" {
  description = "The Massdriver API the onboarding service account calls."
  type        = string
  default     = "https://api.massdriver.cloud"
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
  automations = keys(yamldecode(file("${path.module}/automations.yaml")))

  stages = {
    dev  = { name = "Development", prod = false }
    prod = { name = "Production", prod = true }
  }

  # The onboarding project's environments are apps, not stages.
  stage = { for s in distinct(flatten([for p in local.projects : p.stages])) : s => lookup(local.stages, s, { name = title(s), prod = false }) }

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

    # One set of automations serves the whole organization. main leaves the
    # cluster undeployed and runs on the platform's dev cluster, its environment
    # default; another environment can deploy its own.
    automations = {
      name        = "Automations"
      description = "Massdriver automations for the whole organization: status page, drift checks, change freezes, auto-deploys and more."
      team        = "platform"
      stages      = ["main"]
      components = merge(
        { cluster = { bundle = "ecs-cluster", name = "ECS Cluster" } },
        # Holds automation images built from branches that aren't published yet.
        { registry = { bundle = "ecr-repository", name = "Image Repository" } },
        { for a in local.automations : replace(a, "-", "") => { bundle = "massdriver-${a}-ecs", name = title(replace(a, "-", " ")) } },
      )
      links = [for a in local.automations : "cluster.cluster -> ${replace(a, "-", "")}.ecs_cluster"]
    }

    # Like automations, the cluster stays undeployed and Jimmy runs on the
    # platform's dev cluster, his environment default.
    sreagent = {
      name        = "SRE Agent"
      description = "Claude agents that watch the platform and the apps, each one an environment."
      team        = "platform"
      stages      = ["jimmy"]
      components = {
        registry = { bundle = "ecr-repository", name = "Image Repository" }
        repo     = { bundle = "github-repo", name = "Source Repository" }
        codebase = { bundle = "codebase", name = "Codebase" }
        cluster  = { bundle = "ecs-cluster", name = "ECS Cluster" }
        agent    = { bundle = "ecs-agent", name = "Agent" }
      }
      # repo stays undeployed until the agent's image moves to its own
      # repository; until then bootstrap.sh pushes it straight to the registry.
      links = [
        "registry.repository -> repo.registry",
        "repo.repository -> codebase.repository",
        "registry.repository -> codebase.registry",
        "codebase.codebase -> agent.codebase",
        "cluster.cluster -> agent.cluster",
      ]
    }

    apps = {
      name        = "Apps"
      description = "Onboards each app: its image registry and codebase, and optionally its GitHub repository and Massdriver project. One environment per app."
      team        = "platform"
      stages      = ["visits", "care", "billing"]
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
      ]
    }

    visits = {
      name        = "Visits"
      description = "Patients find an open slot and book a video visit."
      team        = "patient-experience"
      stages      = keys(local.stages)
      components = {
        api       = { bundle = "http-api", name = "Booking API" }
        slots     = { bundle = "dynamodb-table", name = "Slots" }
        reminders = { bundle = "sqs-queue", name = "Reminders Queue" }
        app       = { bundle = "tendwell-visits", name = "Visits" }
        notifier  = { bundle = "tendwell-visits", name = "Reminder Sender" }
      }
      links = [
        "api.api -> app.api",
        "slots.table -> app.table",
        "reminders.queue -> app.queue",
        "api.api -> notifier.api",
        "slots.table -> notifier.table",
        "reminders.queue -> notifier.queue",
      ]
    }

    care = {
      name        = "Care"
      description = "The clinician portal: charts, encounters and visit notes."
      team        = "clinical"
      stages      = keys(local.stages)
      components = {
        charts    = { bundle = "postgres", name = "Charts" }
        sessions  = { bundle = "valkey", name = "Sessions" }
        documents = { bundle = "s3-bucket", name = "Documents" }
        app       = { bundle = "tendwell-care", name = "Care" }
      }
      links = [
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
        ledger = { bundle = "mariadb", name = "Claims Ledger" }
        claims = { bundle = "s3-bucket", name = "Claim Files" }
        app    = { bundle = "tendwell-billing", name = "Billing" }
      }
      links = [
        "ledger.database -> app.mariadb",
        "claims.bucket -> app.bucket",
      ]
    }

    # The template builds the workspace image once: its registry and codebase
    # are deployed there and become every sandbox's default codebase. Forks
    # leave theirs undeployed, like the cluster, which comes from the
    # platform's dev environment.
    sandboxes = {
      name        = "Developer Sandboxes"
      description = "An environment for each developer, forked from the template when they join a team: a workspace with Claude Code, OpenCode and mass, and a VPN into the dev VPC."
      team        = "platform"
      stages      = ["template"]
      components = {
        registry  = { bundle = "ecr-repository", name = "Workspace Image Repository" }
        repo      = { bundle = "github-repo", name = "Source Repository" }
        codebase  = { bundle = "codebase", name = "Workspace Codebase" }
        cluster   = { bundle = "ecs-cluster", name = "ECS Cluster" }
        workspace = { bundle = "dev-workspace", name = "Workspace" }
        vpn       = { bundle = "developer-vpn", name = "Developer VPN" }
      }
      links = [
        "registry.repository -> codebase.registry",
        "registry.repository -> repo.registry",
        "repo.repository -> codebase.repository",
        "codebase.codebase -> workspace.codebase",
        "cluster.cluster -> workspace.cluster",
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

  # The apps redeploy when what they connect to changes, and roll back when a
  # deploy fails.
  runtimes     = ["visits-app", "visits-notifier", "care-app", "billing-app"]
  app_projects = ["visits", "care", "billing"]

  # Every catalog bundle is open to every project; each app's bundle only to its own.
  bundle_access = merge(
    # Bundles that belong to another example's organization stay out of Tendwell's.
    { for f in fileset("${path.module}/../../bundles", "*/massdriver.yaml") : yamldecode(file("${path.module}/../../bundles/${f}")).name => "*"
    if !contains(["lab-box", "ecs-scaling-policy"], yamldecode(file("${path.module}/../../bundles/${f}")).name) },
    { for app in ["visits", "care", "billing"] : yamldecode(file("${path.module}/applications/${app}/bundle/massdriver.yaml")).name => app },
    # A VPN into a shared VPC belongs in a developer's own sandbox, not beside prod.
    { "developer-vpn" = "sandboxes", "dev-workspace" = "sandboxes" },
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
    "stash:write",
    "stash:export",
  ]

  read_actions = ["project:view", "resource:view", "repo:view", "repo:pull", "stash:view"]
}

resource "massdriver_custom_attribute" "team" {
  key    = "team"
  scope  = "PROJECT"
  values = ["platform", "patient-experience", "clinical", "revenue"]
}

resource "massdriver_custom_attribute" "data_classification" {
  key    = "data_classification"
  scope  = "COMPONENT"
  values = ["phi", "internal", "public"]
}

resource "massdriver_organization_settings" "this" {
  # Every bundle's access is granted below, so app bundles stay with their own project.
  grant_new_bundles_to_all_projects = false
  default_tags                      = [massdriver_custom_attribute.team.key, massdriver_custom_attribute.data_classification.key]
}

# The automations act only on components that opt in with these. Which
# values do anything for a team is set in automations.yaml.
resource "massdriver_custom_attribute" "automation" {
  for_each = {
    autodeploy   = ["upstream-changes", "hourly", "daily", "off"]
    autorollback = ["true", "false"]
    driftwatch   = ["drift-hourly", "drift-daily", "reconcile-proposal-hourly", "reconcile-proposal-daily", "off"]
  }

  key    = each.key
  scope  = "COMPONENT"
  values = each.value
}

resource "massdriver_project" "this" {
  for_each = local.projects

  identifier  = each.key
  name        = each.value.name
  description = each.value.description
  attributes  = { team = each.value.team }

  depends_on = [massdriver_custom_attribute.team]
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
  name                    = local.stage[each.value.stage].name
  separation_of_duty      = var.protect_prod && local.stage[each.value.stage].prod
  decommission_protection = var.protect_prod && local.stage[each.value.stage].prod
}

resource "massdriver_component" "this" {
  for_each = local.components

  project_id  = massdriver_project.this[each.value.project].id
  identifier  = each.value.identifier
  name        = each.value.name
  bundle_name = each.value.bundle
  attributes = merge(
    { data_classification = contains(local.phi, each.key) ? "phi" : "internal" },
    contains(local.runtimes, each.key) ? { autodeploy = "upstream-changes", autorollback = "true" } : {},
    contains(local.app_projects, each.value.project) ? { driftwatch = "drift-daily" } : {},
  )

  depends_on = [massdriver_oci_repository_grant.bundle, massdriver_custom_attribute.data_classification, massdriver_custom_attribute.automation]
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

# The apps project's massdriver-project and github-repo bundles create
# projects, groups and service accounts. Platform Engineering may do anything,
# and it owns app onboarding.
resource "massdriver_service_account" "onboarding" {
  name                     = "App Onboarding"
  description              = "Creates each app's Massdriver project and its pipeline's service account."
  token_expiration_minutes = 60 * 24 * 365
}

resource "massdriver_service_account_group_membership" "onboarding" {
  group_id           = massdriver_group.platform.id
  service_account_id = massdriver_service_account.onboarding.id
}

resource "massdriver_imported_resource" "onboarding" {
  name          = "Massdriver App Onboarding"
  resource_type = "massdriver-service-account"
  resource = jsonencode({
    url             = var.massdriver_url
    organization_id = var.organization_id
    api_key         = massdriver_service_account.onboarding.token
  })

  # The API adds the version to the type, as with the AWS credential.
  lifecycle {
    ignore_changes = [resource_type]
  }
}

# Organization admin power stays in the project that onboards apps.
resource "massdriver_resource_grant" "onboarding" {
  resource_id          = massdriver_imported_resource.onboarding.id
  recipient_conditions = jsonencode({ "md-project" = ["apps"] })
}

resource "massdriver_service_account" "automations" {
  name                     = "Automations"
  description              = "Runs Massdriver automations: status page, drift checks, auto-deploy and auto-rollback."
  token_expiration_minutes = 60 * 24 * 365
}

resource "massdriver_service_account_group_membership" "automations" {
  group_id           = massdriver_group.platform.id
  service_account_id = massdriver_service_account.automations.id
}

# The platform's automations bundle creates its event destinations and calls
# the API with this.
resource "massdriver_imported_resource" "automations" {
  name          = "Massdriver Automations"
  resource_type = "massdriver-service-account"
  resource = jsonencode({
    url             = var.massdriver_url
    organization_id = var.organization_id
    api_key         = massdriver_service_account.automations.token
  })

  # The API adds the version to the type, as with the AWS credential.
  lifecycle {
    ignore_changes = [resource_type]
  }
}

resource "massdriver_resource_grant" "automations" {
  resource_id          = massdriver_imported_resource.automations.id
  recipient_conditions = jsonencode({ "md-project" = ["automations"] })
}

# The agent bundle makes each agent's own service account with this, and
# puts it in the groups its form picks.
resource "massdriver_service_account" "sre_agent" {
  name                     = "SRE Agent Provisioner"
  description              = "Creates each SRE agent's service account and the webhook that reports its actions."
  token_expiration_minutes = 60 * 24 * 365
}

resource "massdriver_service_account_group_membership" "sre_agent" {
  group_id           = massdriver_group.platform.id
  service_account_id = massdriver_service_account.sre_agent.id
}

resource "massdriver_imported_resource" "sre_agent" {
  name          = "Massdriver SRE Agent Provisioner"
  resource_type = "massdriver-service-account"
  resource = jsonencode({
    url             = var.massdriver_url
    organization_id = var.organization_id
    api_key         = massdriver_service_account.sre_agent.token
  })

  # The API adds the version to the type, as with the AWS credential.
  lifecycle {
    ignore_changes = [resource_type]
  }
}

resource "massdriver_resource_grant" "sre_agent" {
  resource_id          = massdriver_imported_resource.sre_agent.id
  recipient_conditions = jsonencode({ "md-project" = ["sreagent"] })
}

# The workspace bundle makes each sandbox's own service account with this,
# and puts it in the groups its form picks.
resource "massdriver_service_account" "sandbox" {
  name                     = "Sandbox Provisioner"
  description              = "Creates the service account each developer sandbox's workspace signs in to Massdriver with."
  token_expiration_minutes = 60 * 24 * 365
}

resource "massdriver_service_account_group_membership" "sandbox" {
  group_id           = massdriver_group.platform.id
  service_account_id = massdriver_service_account.sandbox.id
}

resource "massdriver_imported_resource" "sandbox" {
  name          = "Massdriver Sandbox Provisioner"
  resource_type = "massdriver-service-account"
  resource = jsonencode({
    url             = var.massdriver_url
    organization_id = var.organization_id
    api_key         = massdriver_service_account.sandbox.token
  })

  # The API adds the version to the type, as with the AWS credential.
  lifecycle {
    ignore_changes = [resource_type]
  }
}

resource "massdriver_resource_grant" "sandbox" {
  resource_id          = massdriver_imported_resource.sandbox.id
  recipient_conditions = jsonencode({ "md-project" = ["sandboxes"] })
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

# What the SRE agents may do: read everything, tune dev themselves, and only
# propose in prod, where a person approves.
resource "massdriver_group" "sre_agents" {
  name        = "SRE Agents"
  description = "Claude agents. Read everything; tune dev; propose in prod."
}

resource "massdriver_group_policy" "sre_agents_read" {
  group_id   = massdriver_group.sre_agents.id
  effect     = "ALLOW"
  actions    = local.read_actions
  conditions = "*"
}

resource "massdriver_group_policy" "sre_agents_tune_dev" {
  group_id   = massdriver_group.sre_agents.id
  effect     = "ALLOW"
  actions    = ["environment:configure", "instance:configure", "instance:plan", "instance:propose", "instance:deploy", "stash:write", "stash:export"]
  conditions = jsonencode({ "md-environment" = ["dev"] })
}

resource "massdriver_group_policy" "sre_agents_propose_prod" {
  group_id   = massdriver_group.sre_agents.id
  effect     = "ALLOW"
  actions    = ["instance:plan", "instance:propose"]
  conditions = jsonencode({ "md-environment" = ["prod"] })
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
      credential = massdriver_imported_resource.aws[local.stage[e.stage].prod ? "prod" : "nonprod"].id
    }
  }
}

output "one_account" {
  value = split(":", var.aws_accounts.nonprod.arn)[4] == split(":", var.aws_accounts.prod.arn)[4]
}

output "onboarding_credential" {
  value = massdriver_imported_resource.onboarding.id
}

resource "random_password" "cost_explorer" {
  length  = 24
  special = false
}

output "cost_explorer_password" {
  value     = random_password.cost_explorer.result
  sensitive = true
}

# The automations' and agents' forms pick groups by ID, which changes with each bootstrap.
output "group_ids" {
  value = merge(
    { (massdriver_group.platform.name) = massdriver_group.platform.id },
    { (massdriver_group.sre_agents.name) = massdriver_group.sre_agents.id },
    { for g in massdriver_group.team : g.name => g.id },
  )
}

output "automations_api_key" {
  value     = massdriver_service_account.automations.token
  sensitive = true
}

output "automations_credential" {
  value = massdriver_imported_resource.automations.id
}

output "sre_agent_credential" {
  value = massdriver_imported_resource.sre_agent.id
}

output "sandbox_provisioner_credential" {
  value = massdriver_imported_resource.sandbox.id
}

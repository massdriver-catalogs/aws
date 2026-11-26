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

locals {
  apps = toset([for f in fileset("${path.module}/applications", "*/massdriver.yaml") : dirname(f)])

  bundles = { for app in local.apps : app => yamldecode(file("${path.module}/applications/${app}/massdriver.yaml")).name }

  components = merge(
    {
      registry = { bundle = "ecr-repository", name = "Image Repository" }
      codebase = { bundle = "codebase", name = "Codebase" }
    },
    { for app in local.apps : app => { bundle = local.bundles[app], name = title(app) } },
  )

  links = merge(
    { registry = { from = "registry", from_field = "repository", to = "codebase", to_field = "registry" } },
    { for app in local.apps : app => { from = "codebase", from_field = "codebase", to = app, to_field = "codebase" } },
  )
}

# The team attribute and its values belong to the telehealth example's bootstrap.
resource "massdriver_project" "phpfleet" {
  identifier  = "phpfleet"
  name        = "PHP Fleet"
  description = "Tendwell Supply, the home-health supply shop: seven PHP services on the ECS service runtime, partway through a runtime upgrade."
  attributes  = { team = "platform" }
}

# Dev only. The apps run on the platform project's dev cluster, which is
# already shared with every dev environment.
resource "massdriver_environment" "dev" {
  project_id = massdriver_project.phpfleet.id
  identifier = "dev"
  name       = "Development"
}

# The organization doesn't grant new bundles to every project, so each app's
# bundle is opened to this project only.
resource "massdriver_oci_repository" "app" {
  for_each = local.bundles

  name          = each.value
  artifact_type = "BUNDLE"
}

resource "massdriver_oci_repository_grant" "app" {
  for_each = local.bundles

  repository_id        = massdriver_oci_repository.app[each.key].id
  recipient_conditions = jsonencode({ "md-project" = ["phpfleet"] })
}

resource "massdriver_component" "this" {
  for_each = local.components

  project_id  = massdriver_project.phpfleet.id
  identifier  = each.key
  name        = each.value.name
  bundle_name = each.value.bundle
  attributes  = { data_classification = "internal" }

  depends_on = [massdriver_oci_repository_grant.app]
}

resource "massdriver_component_link" "this" {
  for_each = local.links

  from_component_id = massdriver_component.this[each.value.from].id
  from_field        = each.value.from_field
  to_component_id   = massdriver_component.this[each.value.to].id
  to_field          = each.value.to_field
}

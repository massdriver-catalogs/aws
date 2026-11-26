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

  runtimes = { for f in fileset("${path.module}/runtimes", "*/runtime.yaml") : dirname(f) => yamldecode(file("${path.module}/runtimes/${f}")).name }

  app_bundles = { for app in local.apps : app => yamldecode(file("${path.module}/applications/${app}/massdriver.yaml")).name }

  bundles = merge(local.app_bundles, local.runtimes)

  components = merge(
    {
      registry = { bundle = "ecr-repository", name = "Image Repository" }
      codebase = { bundle = "codebase", name = "Codebase" }
    },
    { for app in local.apps : app => { bundle = local.app_bundles[app], name = title(app) } },
  )
}

# The team attribute and its values belong to the telehealth example's bootstrap.
resource "massdriver_project" "phpfleet" {
  identifier  = "phpfleet"
  name        = "PHP Fleet"
  description = "Tendwell Supply, the home-health supply shop: seven PHP services partway through a PHP 7 upgrade."
  attributes  = { team = "platform" }
}

# Dev only. The apps run on the platform project's dev cluster, which is
# already shared with every dev environment.
resource "massdriver_environment" "dev" {
  project_id = massdriver_project.phpfleet.id
  identifier = "dev"
  name       = "Development"
}

# The organization doesn't grant new bundles to every project, so the PHP
# runtimes and the apps are opened to this project only.
resource "massdriver_oci_repository" "bundle" {
  for_each = local.bundles

  name          = each.value
  artifact_type = "BUNDLE"
}

resource "massdriver_oci_repository_grant" "bundle" {
  for_each = local.bundles

  repository_id        = massdriver_oci_repository.bundle[each.key].id
  recipient_conditions = jsonencode({ "md-project" = ["phpfleet"] })
}

resource "massdriver_component" "this" {
  for_each = local.components

  project_id  = massdriver_project.phpfleet.id
  identifier  = each.key
  name        = each.value.name
  bundle_name = each.value.bundle
  attributes  = { data_classification = "internal" }

  depends_on = [massdriver_oci_repository_grant.bundle]
}

# The apps get the codebase as an environment default, from deploy.sh.
resource "massdriver_component_link" "registry" {
  from_component_id = massdriver_component.this["registry"].id
  from_field        = "repository"
  to_component_id   = massdriver_component.this["codebase"].id
  to_field          = "registry"
}

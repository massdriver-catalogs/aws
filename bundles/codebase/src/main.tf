resource "massdriver_resource" "codebase" {
  field = "codebase"
  name  = "Codebase ${var.repository != null ? var.repository.full_name : var.registry.name}"
  resource = jsonencode(merge({
    registry = {
      name        = var.registry.name
      arn         = var.registry.arn
      url         = var.registry.url
      region      = var.registry.region
      registry_id = var.registry.registry_id
      policies    = [for p in var.registry.policies : { name = p.name, arn = p.arn }]
    }
    # Bundles that consume a codebase already run in the project it was made
    # for, so the project would be a second source of truth. Uncomment it here
    # and in the aws-codebase resource type when bundles need it.
    # project = {
    #   identifier   = var.project.identifier
    #   name         = var.project.name
    #   environments = [for e in var.project.environments : e.identifier]
    # }
    }, var.repository == null ? {} : {
    repository = {
      full_name      = var.repository.full_name
      url            = var.repository.url
      clone_url      = var.repository.clone_url
      ssh_url        = var.repository.ssh_url
      default_branch = var.repository.default_branch
      visibility     = var.repository.visibility
    }
  }))

  lifecycle {
    precondition {
      condition     = !var.share_with_project || (var.project != null && var.massdriver != null)
      error_message = "Share with the project needs the Massdriver project and the Massdriver service account connected. Connect both, or turn sharing off to link the codebase in its own project."
    }
  }
}

resource "massdriver_resource_grant" "project" {
  count                = var.share_with_project ? 1 : 0
  provider             = massdriver.admin
  resource_id          = massdriver_resource.codebase.id
  recipient_conditions = jsonencode({ md-project = [var.project.identifier] })
}

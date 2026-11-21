variable "onboarding" {
  description = "The project that onboards apps."
  type = object({
    identifier  = string
    name        = string
    description = optional(string)
    attributes  = optional(map(string), {})
  })
  default = {
    identifier  = "apps"
    name        = "Apps"
    description = "Mints each application's Massdriver project, GitHub repository and ECR repository. One environment per application."
  }
}

variable "applications" {
  description = "Environments, one per app, keyed by identifier. Attributes are environment attributes, e.g. application and team."
  type = map(object({
    name       = string
    attributes = optional(map(string), {})
  }))
  default = {}
}

variable "catalog_publishers" {
  description = "The group and service account GitHub Actions uses to publish the catalog. Leave null when publishing is already set up."
  type = object({
    group           = string
    service_account = string
  })
  default = null
}

variable "token_expiration_minutes" {
  description = "How long the catalog publisher's token stays valid. Changing it replaces the service account and its token."
  type        = number
  default     = 525600
}

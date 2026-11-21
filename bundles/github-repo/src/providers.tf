terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
    massdriver = {
      source  = "massdriver-cloud/massdriver"
      version = "~> 2.4"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }
}

provider "github" {
  owner = var.github.owner
  app_auth {
    id              = var.github.app_id
    installation_id = var.github.installation_id
    pem_file        = var.github.private_key
  }
}

# IAM is global; the registry's region only satisfies the provider.
provider "aws" {
  region = var.registry.region
  assume_role_with_web_identity {
    role_arn                = var.aws_authentication.arn
    session_name            = var.md_metadata.name_prefix
    web_identity_token_file = "/massdriver/oidc/${var.aws_authentication.token_level}.jwt"
  }
  default_tags {
    tags = var.md_metadata.default_tags
  }
}

# Deployment tokens can't manage service accounts, so these resources use the
# credential's API key. The default provider stays on the deployment token.
provider "massdriver" {
  alias           = "admin"
  api_key         = var.massdriver.token
  organization_id = var.massdriver.organization_id
}

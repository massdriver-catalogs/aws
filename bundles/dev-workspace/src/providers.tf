terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    massdriver = {
      source = "massdriver-cloud/massdriver"
      version = "~> 2.5"
    }
  }
}

provider "aws" {
  region = var.cluster.region
  assume_role_with_web_identity {
    role_arn                = var.aws_authentication.arn
    session_name            = var.md_metadata.name_prefix
    web_identity_token_file = "/massdriver/oidc/${var.aws_authentication.token_level}.jwt"
  }
  default_tags {
    tags = var.md_metadata.default_tags
  }
}

# A deployment's own token can't create service accounts or join them to
# groups, so the provider uses the connected credential.
provider "massdriver" {
  url             = var.massdriver.url
  organization_id = var.massdriver.organization_id
  api_key         = var.massdriver.api_key
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

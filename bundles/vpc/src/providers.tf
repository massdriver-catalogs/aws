terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    massdriver = {
      source  = "massdriver-cloud/massdriver"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.region
  assume_role_with_web_identity {
    role_arn                = var.aws_authentication.arn
    session_name            = var.md_metadata.name_prefix
    web_identity_token_file = "/massdriver/oidc/${var.aws_authentication.token_level}.jwt"
  }
  default_tags {
    tags = var.md_metadata.default_tags
  }
}

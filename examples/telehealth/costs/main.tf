terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# Cost and Usage Report definitions only exist in us-east-1.
provider "aws" {
  region = "us-east-1"
}

module "cur" {
  source        = "github.com/massdriver-cloud/integrations//aws-cost-and-usage-reports?ref=91600ba"
  bucket_region = "us-east-1"
}

output "massdriver_integration_config" {
  value     = module.cur.massdriver_integration_config
  sensitive = true
}

# -------------------------------------------------------------------------
# Terraform Settings, HCP Terraform Cloud Backend, and AWS Provider
# -------------------------------------------------------------------------

terraform {
  required_version = ">= 1.10"

  # Remote state & execution in HCP Terraform (Workspace: SuccessfulSuccess_spry-dev)
  cloud {
    organization = "ooad-OlenaPasiura"
    workspaces {
      name = "SuccessfulSuccess_spry-dev"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

# AWS Provider configured with dynamic OIDC credentials in HCP Terraform
provider "aws" {
  region = var.region

  default_tags {
    tags = {
      PROJECT_NAME = var.project_name
      ManagedBy    = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 6.0.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    bucket = "bc-uatms-terraform-state"
    key    = "v8/environments/bc-prd/terraform.tfstate"
    region = "eu-central-1"
  }
}

provider "aws" {
  region = local.region
}

data "terraform_remote_state" "ctrl" {
  backend = "s3"
  config = {
    bucket = "bc-uatms-terraform-state"
    key    = "v8/environments/bc-ctrl/terraform.tfstate"
    region = "eu-central-1"
  }
}

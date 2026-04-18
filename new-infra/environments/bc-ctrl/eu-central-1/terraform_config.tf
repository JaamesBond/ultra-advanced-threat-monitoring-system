terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.23"
    }
  }

  backend "s3" {
    bucket = "bc-uatms-terraform-state"
    key    = "v8/environments/bc-ctrl/terraform.tfstate"
    region = "eu-central-1"
  }
}

provider "aws" {
  region = local.region
}

data "terraform_remote_state" "prd" {
  backend = "s3"
  config = {
    bucket = "bc-uatms-terraform-state"
    key    = "v8/environments/bc-prd/terraform.tfstate"
    region = "eu-central-1"
  }
}

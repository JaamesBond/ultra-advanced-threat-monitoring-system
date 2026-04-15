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
    key    = "environments/bc-xdr/terraform.tfstate"
    region = "eu-central-1"
  }
}

provider "aws" {
  region = local.region
}

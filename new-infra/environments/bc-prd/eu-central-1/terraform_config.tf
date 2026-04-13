terraform {
  required_version = ">= 1.5.7"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.23"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }

  backend "s3" {
    bucket = "bc-uatms-terraform-state"
    key    = "environments/bc-prd/terraform.tfstate"
    region = "eu-central-1"
  }
}

provider "aws" {
  region = local.region
}

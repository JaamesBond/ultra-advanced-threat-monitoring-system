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
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    bucket = "bc-uatms-terraform-state-997916278486"
    key    = "v8/environments/bc-prd/terraform.tfstate"
    region = "eu-central-1"
  }
}

provider "aws" {
  region = local.region
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
    command     = "aws"
  }
}

data "aws_caller_identity" "current" {}

# Resolve the SSO AdministratorAccess role dynamically so the random suffix
# in the role name never causes drift between accounts or SSO re-deployments.
data "aws_iam_roles" "sso_admin" {
  name_regex  = "AWSReservedSSO_AdministratorAccess_.*"
  path_prefix = "/aws-reserved/sso.amazonaws.com/"
}

data "terraform_remote_state" "ctrl" {
  backend = "s3"
  config = {
    bucket = "bc-uatms-terraform-state-997916278486"
    key    = "v8/environments/bc-ctrl/terraform.tfstate"
    region = "eu-central-1"
  }
}

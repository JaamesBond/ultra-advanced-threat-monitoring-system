#--------------------------------------------------------------
# Shared — ECR Pull-Through Cache
#
# Creates ECR pull-through cache rules for the upstream registries
# Big Chemistry depends on. First pull from any VPC (via the ECR
# VPC interface endpoint) transparently fetches from upstream and
# caches in a local ECR repo; subsequent pulls never leave AWS.
#
# Required for bc-prd: the production spoke has no internet egress,
# so it can ONLY pull images through ECR. Every image reference in
# bc-prd must use the pull-through prefix (docker-hub/, quay/, ghcr/).
#
# Deploy:
#   cd new-infra/shared/ecr-pull-through-cache
#   terraform init && terraform apply
#
# After apply you must populate the Docker Hub credential secret
# manually (one-time), otherwise rate-limited anonymous pulls:
#   aws secretsmanager put-secret-value \
#     --secret-id ecr-pullthroughcache/docker-hub \
#     --secret-string '{"username":"<user>","accessToken":"<PAT>"}'
#--------------------------------------------------------------

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
    key    = "shared/ecr-pull-through-cache/terraform.tfstate"
    region = "eu-central-1"
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

locals {
  common_tags = {
    Customer     = "Big Chemistry"
    Environment  = "shared"
    Confidential = "yes"
    IACTool      = "Terraform"
    Component    = "ecr-pull-through-cache"
  }
}

#--------------------------------------------------------------
# 1. Docker Hub — requires credentials to bypass anon rate limit
#--------------------------------------------------------------
resource "aws_secretsmanager_secret" "docker_hub" {
  name        = "ecr-pullthroughcache/docker-hub"
  description = "Docker Hub credentials used by ECR pull-through cache"

  tags = local.common_tags
}

# ECR requires the secret name to be prefixed with "ecr-pullthroughcache/"
# and the value to be: {"username":"...","accessToken":"..."}
resource "aws_secretsmanager_secret_version" "docker_hub_placeholder" {
  secret_id = aws_secretsmanager_secret.docker_hub.id
  secret_string = jsonencode({
    username    = "PLACEHOLDER_DOCKERHUB_USER"
    accessToken = "PLACEHOLDER_DOCKERHUB_PAT"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

resource "aws_ecr_pull_through_cache_rule" "docker_hub" {
  ecr_repository_prefix = "docker-hub"
  upstream_registry_url = "registry-1.docker.io"
  credential_arn        = aws_secretsmanager_secret.docker_hub.arn

  depends_on = [aws_secretsmanager_secret_version.docker_hub_placeholder]
}

#--------------------------------------------------------------
# 2. Quay — anonymous, no creds needed
#--------------------------------------------------------------
resource "aws_ecr_pull_through_cache_rule" "quay" {
  ecr_repository_prefix = "quay"
  upstream_registry_url = "quay.io"
}

#--------------------------------------------------------------
# 3. GitHub Container Registry — anonymous
#--------------------------------------------------------------
resource "aws_ecr_pull_through_cache_rule" "ghcr" {
  ecr_repository_prefix = "ghcr"
  upstream_registry_url = "ghcr.io"
}

#--------------------------------------------------------------
# 4. Kubernetes registry (gcr-backed) — for kube-proxy, pause, etc.
#--------------------------------------------------------------
resource "aws_ecr_pull_through_cache_rule" "k8s" {
  ecr_repository_prefix = "k8s"
  upstream_registry_url = "registry.k8s.io"
}

#--------------------------------------------------------------
# 5. ECR Public — for AWS maintained images
#--------------------------------------------------------------
resource "aws_ecr_pull_through_cache_rule" "ecr_public" {
  ecr_repository_prefix = "ecr-public"
  upstream_registry_url = "public.ecr.aws"
}

#--------------------------------------------------------------
# Registry-level scanning configuration (CRITICAL scan on push)
#--------------------------------------------------------------
resource "aws_ecr_registry_scanning_configuration" "this" {
  scan_type = "ENHANCED"

  rule {
    scan_frequency = "CONTINUOUS_SCAN"
    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }
}

#--------------------------------------------------------------
# Repository creation template — applies to auto-created cache repos
# Forces image tag immutability + encryption on every new cache repo
#--------------------------------------------------------------
resource "aws_ecr_repository_creation_template" "pull_through" {
  prefix               = "ROOT"
  description          = "Default settings for pull-through cache repos"
  applied_for          = ["PULL_THROUGH_CACHE"]
  image_tag_mutability = "IMMUTABLE"

  encryption_configuration {
    encryption_type = "AES256"
  }

  resource_tags = local.common_tags
}

#==============================================================
# Production EKS Cluster
# Private endpoint only — no public subnets in prd VPC.
#==============================================================

# Import pre-existing addons into state.
# EKS auto-creates coredns; ebs-csi-driver exists in CREATE_FAILED (IAM issue fixed by
# pod identity association below — import so Terraform updates rather than re-creates).
import {
  to = module.eks.aws_eks_addon.this["coredns"]
  id = "bc-prd-eks:coredns"
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = local.eks_cluster_name
  kubernetes_version = local.eks_cluster_version

  endpoint_public_access  = local.eks_endpoint_public_access
  endpoint_private_access = local.eks_endpoint_private_access

  enable_irsa         = local.eks_enable_irsa
  deletion_protection = local.eks_deletion_protection

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  addons = {
    kube-proxy = {
      addon_version               = local.eks_addons["kube-proxy"].addon_version
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      before_compute              = true
    }

    eks-pod-identity-agent = {
      addon_version               = local.eks_addons["eks-pod-identity-agent"].addon_version
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      before_compute              = true
    }

    vpc-cni = {
      addon_version               = local.eks_addons["vpc-cni"].addon_version
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      before_compute              = true
    }

    coredns = {
      addon_version               = local.eks_addons["coredns"].addon_version
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }

    amazon-cloudwatch-observability = {
      addon_version               = local.eks_addons["amazon-cloudwatch-observability"].addon_version
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }
  }

  eks_managed_node_groups = local.eks_node_groups

  # Allow the self-hosted GitHub Actions runner (in this VPC) to reach the
  # private EKS API endpoint for Helm + kubernetes_manifest resources.
  cluster_security_group_additional_rules = {
    runner_https = {
      description = "GitHub Actions runner to EKS API"
      protocol    = "tcp"
      from_port   = 443
      to_port     = 443
      type        = "ingress"
      cidr_blocks = [local.vpc_cidr]
    }
  }

  tags = local.common_tags
}

#--------------------------------------------------------------
# Outputs — EKS
#--------------------------------------------------------------

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "eks_node_group_arns" {
  value = { for k, v in module.eks.eks_managed_node_groups : k => v.node_group_arn }
}

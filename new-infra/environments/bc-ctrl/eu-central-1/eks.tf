#==============================================================
# Control Plane EKS Cluster
# Access: private endpoint only
#==============================================================

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

  # Addons deferred — CoreDNS + ebs-csi + cloudwatch require nodes to reach ACTIVE state.
  # SCP p-bg731gel blocks ec2:RunInstances; restore addons once SCP is resolved.
  addons = {}

  eks_managed_node_groups = {} # blocked by SCP p-bg731gel

  tags = local.common_tags
}

output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "eks_node_group_arns" {
  value = { for k, v in module.eks.eks_managed_node_groups : k => v.node_group_arn }
}

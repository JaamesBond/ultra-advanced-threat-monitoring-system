#==============================================================
# Production EKS Cluster
#
# Single workload node group (m6a.large, ON_DEMAND).
# Cilium, Falco, and Tetragon installed via Helm (helm.tf).
# Private endpoint only — no public subnets in prd VPC.
#==============================================================

data "aws_iam_policy_document" "eks_pod_identity_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "addon_ebs_csi" {
  name               = "${local.eks_cluster_name}-addon-ebs-csi"
  assume_role_policy = data.aws_iam_policy_document.eks_pod_identity_trust.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "addon_ebs_csi" {
  role       = aws_iam_role.addon_ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_iam_role" "addon_cloudwatch" {
  name               = "${local.eks_cluster_name}-addon-cloudwatch"
  assume_role_policy = data.aws_iam_policy_document.eks_pod_identity_trust.json
  tags               = local.common_tags
}

resource "aws_iam_role_policy_attachment" "addon_cloudwatch" {
  role       = aws_iam_role.addon_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
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

    vpc-cni = {
      addon_version               = local.eks_addons["vpc-cni"].addon_version
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      before_compute              = true
      # vpc-cni does not support Pod Identity — node IAM role carries AmazonEKS_CNI_Policy
    }

    coredns = {
      addon_version               = local.eks_addons["coredns"].addon_version
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
    }

    aws-ebs-csi-driver = {
      addon_version               = local.eks_addons["aws-ebs-csi-driver"].addon_version
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      pod_identity_association = [{
        role_arn        = aws_iam_role.addon_ebs_csi.arn
        service_account = "kube-system:ebs-csi-controller-sa"
      }]
    }

    amazon-cloudwatch-observability = {
      addon_version               = local.eks_addons["amazon-cloudwatch-observability"].addon_version
      resolve_conflicts_on_create = "OVERWRITE"
      resolve_conflicts_on_update = "OVERWRITE"
      pod_identity_association = [{
        role_arn        = aws_iam_role.addon_cloudwatch.arn
        service_account = "amazon-cloudwatch:cloudwatch-agent"
      }]
    }
  }

  eks_managed_node_groups = {} # node groups disabled — SCP p-bg731gel blocks ec2:RunInstances

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

locals {
  region        = "eu-central-1"
  company       = "big-chemistry"
  env           = "ctrl"
  platform_name = "bc-uatms"

  vpc_cidr = "10.0.0.0/16"
  azs      = ["eu-central-1a"]

  common_tags = {
    Project     = "UATMS"
    Environment = local.env
    Customer    = "Big Chemistry"
    IACTool     = "Terraform"
  }

  #--------------------------------------------------------------
  # EKS — bc-ctrl-eks (hosts Wazuh Manager/Indexer/Dashboard)
  #--------------------------------------------------------------
  eks_cluster_name    = "${local.platform_name}-${local.env}-eks"
  eks_cluster_version = "1.35"

  eks_endpoint_public_access  = false
  eks_endpoint_private_access = true
  eks_enable_irsa             = true
  eks_deletion_protection     = false

  eks_node_groups = {
    security = {
      instance_types = ["t3.xlarge"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      labels         = { role = "security" }
    }
  }

  eks_addons = {
    kube-proxy = {
      addon_version              = "v1.35.0-eksbuild.2"
      service_account_namespace  = null
      service_account_name       = null
      iam_policy_arn             = null
    }
    eks-pod-identity-agent = {
      addon_version              = "v1.3.2-eksbuild.2"
      service_account_namespace  = null
      service_account_name       = null
      iam_policy_arn             = null
    }
    vpc-cni = {
      addon_version              = "v1.19.0-eksbuild.1"
      service_account_namespace  = "kube-system"
      service_account_name       = "aws-node"
      iam_policy_arn             = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
    }
    coredns = {
      addon_version              = "v1.11.4-eksbuild.2"
      service_account_namespace  = null
      service_account_name       = null
      iam_policy_arn             = null
    }
    amazon-cloudwatch-observability = {
      addon_version              = "v2.3.0-eksbuild.1"
      service_account_namespace  = "amazon-cloudwatch"
      service_account_name       = "cloudwatch-agent"
      iam_policy_arn             = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
    }
  }
}

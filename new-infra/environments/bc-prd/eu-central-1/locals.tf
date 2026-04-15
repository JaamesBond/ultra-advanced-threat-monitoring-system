locals {
  #--------------------------------------------------------------
  # General
  #--------------------------------------------------------------
  company       = "big-chemistry"
  env           = "prd"
  platform_name = "bc"
  customer_name = "Big Chemistry"
  region        = "eu-central-1"

  common_tags = {
    Customer     = local.customer_name
    Environment  = local.env
    Confidential = "yes"
    IACTool      = "Terraform"
    VPCRole      = "production-spoke"
  }

  #--------------------------------------------------------------
  # Networking — Production VPC
  # Private subnets only. No IGW, no NAT.
  # AWS API access via VPC endpoints. Cross-VPC via peering to bc-ctrl.
  #--------------------------------------------------------------
  vpc_cidr           = "10.30.0.0/16"
  # EKS control plane requires subnets in at least 2 AZs — 1 AZ is rejected
  # by AWS with InvalidRequestException. Keep 2 AZs as the minimum viable config.
  availability_zones = ["eu-central-1a", "eu-central-1b"]

  subnet_cidr_private = ["10.30.10.0/24", "10.30.11.0/24"]

  flowlog_traffic_type         = "ALL"
  flowlog_aggregation_interval = 60

  ctrl_vpc_cidr = "10.0.0.0/16"

  #--------------------------------------------------------------
  # EKS Cluster
  #--------------------------------------------------------------
  eks_cluster_name            = "${local.platform_name}-${local.env}-eks"
  eks_cluster_version         = "1.35"
  eks_endpoint_public_access  = false
  eks_endpoint_private_access = true
  eks_enable_irsa             = true
  eks_deletion_protection     = true
  deploy_security_helm        = true    # Tetragon + Falco + TracingPolicies
  deploy_cilium_helm          = true    # Cilium CNI chaining + network policies
  deploy_flux                 = false   # enable after Tetragon/Falco/Cilium confirmed working
  github_repo_url             = "https://github.com/JaamesBond/ultra-advanced-threat-monitoring-system"

  #--------------------------------------------------------------
  # EKS Node Groups — Production Spoke
  #
  # Application workloads. Security sensors (Wazuh Agent, Falco,
  # Tetragon, Cilium, Fluent Bit) all run as DaemonSets on every
  # node — no dedicated node groups required for them.
  #
  # workload (t3.small — 2 vCPU/2 GB): general application pods
  # spot     (t3.small — 2 vCPU/2 GB, SPOT): fault-tolerant batch
  #--------------------------------------------------------------
  eks_node_group_defaults = {
    ami_type       = "AL2023_x86_64_STANDARD"
    capacity_type  = "ON_DEMAND"
    instance_types = ["t3.small"]
  }

  eks_node_groups = {
    # Application workloads + Cilium/Falco/Tetragon DaemonSets
    # Spot node group omitted — not in scope for this test stage
    workload = {
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      instance_types = ["t3.large"]
      labels         = { "role" = "workload" }
      iam_role_additional_policies = {
        ssm = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 2
      }
      block_device_mappings = {
        xvda = {
          device_name = "/dev/xvda"
          ebs = {
            volume_size           = 100
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
    }
  }

  eks_addons = {
    kube-proxy = {
      addon_version  = "v1.35.3-eksbuild.2"
      before_compute = true
    }
    eks-pod-identity-agent = {
      addon_version  = "v1.3.10-eksbuild.3"
      before_compute = true
    }
    vpc-cni = {
      addon_version             = "v1.21.1-eksbuild.7"
      before_compute            = true
      use_pod_identity          = true
      iam_policy_type           = "managed"
      iam_policy_arn            = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
      service_account_namespace = "kube-system"
      service_account_name      = "aws-node"
    }
    coredns = {
      addon_version = "v1.13.2-eksbuild.4"
    }
    amazon-cloudwatch-observability = {
      addon_version             = "v4.8.0-eksbuild.1"
      use_pod_identity          = true
      iam_policy_type           = "managed"
      iam_policy_arn            = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
      service_account_namespace = "amazon-cloudwatch"
      service_account_name      = "cloudwatch-agent"
    }
  }
}

data "terraform_remote_state" "ctrl" {
  backend = "s3"
  config = {
    bucket = "bc-uatms-terraform-state"
    key    = "environments/bc-ctrl/terraform.tfstate"
    region = "eu-central-1"
  }
}

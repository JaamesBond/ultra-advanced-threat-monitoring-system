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
  # Networking — Production Spoke VPC
  # ZERO public subnets. No IGW. No NAT Gateway.
  # All egress routes via TGW → XDR Infrastructure VPC.
  #--------------------------------------------------------------
  vpc_cidr           = "10.30.0.0/16"
  availability_zones = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]

  subnet_cidr_private = ["10.30.10.0/24", "10.30.11.0/24", "10.30.12.0/24"]
  subnet_cidr_tgw     = ["10.30.240.0/28", "10.30.240.16/28", "10.30.240.32/28"]

  flowlog_traffic_type         = "ALL"
  flowlog_aggregation_interval = 60

  #--------------------------------------------------------------
  # Transit Gateway — Production goes on spoke-rt
  #--------------------------------------------------------------
  tgw_id        = data.terraform_remote_state.tgw.outputs.tgw_id
  tgw_rt_id     = data.terraform_remote_state.tgw.outputs.spoke_rt_id
  tgw_shared_rt = data.terraform_remote_state.tgw.outputs.shared_rt_id

  xdr_vpc_cidr  = "10.11.0.0/16"
  ctrl_vpc_cidr = "10.0.0.0/16"

  #--------------------------------------------------------------
  # EKS Cluster
  #--------------------------------------------------------------
  eks_cluster_name            = "${local.platform_name}-${local.env}-eks"
  eks_cluster_version         = "1.34"
  eks_endpoint_public_access  = false
  eks_endpoint_private_access = true
  eks_enable_irsa             = true
  eks_deletion_protection     = true

  #--------------------------------------------------------------
  # EKS Node Groups — Production Spoke
  #
  # Application workloads. Security sensors (Wazuh Agent, Falco,
  # Tetragon, Cilium, Fluent Bit) all run as DaemonSets on every
  # node — no dedicated node groups required for them.
  #
  # workload (m6a.large  — 2 vCPU/ 8 GB): general application pods
  # spot     (m6a.large  — 2 vCPU/ 8 GB, SPOT): fault-tolerant batch
  #--------------------------------------------------------------
  eks_node_group_defaults = {
    ami_type       = "AL2023_x86_64_STANDARD"
    capacity_type  = "ON_DEMAND"
    disk_size      = 100
    instance_types = ["m6a.large"]
  }

  eks_node_groups = {
    # General application workloads + all security DaemonSets
    workload = {
      min_size       = 2
      max_size       = 10
      desired_size   = 2
      instance_types = ["m6a.large"]
      disk_size      = 100
      labels         = { "role" = "workload" }
    }

    # Fault-tolerant batch / background jobs (Spot, scales to 0 at idle)
    spot = {
      min_size       = 0
      max_size       = 10
      desired_size   = 0
      capacity_type  = "SPOT"
      instance_types = ["m6a.large", "m6a.xlarge", "m5a.large"]
      disk_size      = 100
      labels         = { "role" = "batch" }
      taints = [
        {
          key    = "dedicated"
          value  = "batch"
          effect = "NO_SCHEDULE"
        }
      ]
    }
  }

  eks_addons = {
    kube-proxy = {
      addon_version  = "v1.34.1-eksbuild.2"
      before_compute = true
    }
    vpc-cni = {
      addon_version             = "v1.21.1-eksbuild.1"
      before_compute            = true
      use_pod_identity          = true
      iam_policy_type           = "managed"
      iam_policy_arn            = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
      service_account_namespace = "kube-system"
      service_account_name      = "aws-node"
    }
    coredns = {
      addon_version = "v1.12.4-eksbuild.1"
    }
    aws-ebs-csi-driver = {
      addon_version             = "v1.54.0-eksbuild.1"
      use_pod_identity          = true
      iam_policy_type           = "managed"
      iam_policy_arn            = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      service_account_namespace = "kube-system"
      service_account_name      = "ebs-csi-controller-sa"
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

data "terraform_remote_state" "tgw" {
  backend = "s3"
  config = {
    bucket = "bc-uatms-terraform-state"
    key    = "shared/transit-gateway/terraform.tfstate"
    region = "eu-central-1"
  }
}

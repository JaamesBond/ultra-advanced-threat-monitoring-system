locals {
  #--------------------------------------------------------------
  # General
  #--------------------------------------------------------------
  company       = "big-chemistry"
  env           = "xdr"
  platform_name = "bc"
  customer_name = "Big Chemistry"
  region        = "eu-central-1"

  common_tags = {
    Customer     = local.customer_name
    Environment  = local.env
    Confidential = "yes"
    IACTool      = "Terraform"
    VPCRole      = "xdr-infrastructure"
  }

  #--------------------------------------------------------------
  # Networking — XDR Infrastructure VPC
  #
  # CIDR 10.11.0.0/16 in this fresh env.
  # (In the final multi-account design this becomes 10.10.0.0/16)
  #--------------------------------------------------------------
  vpc_cidr           = "10.11.0.0/16"
  availability_zones = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]

  # Public Ingress — 1 AZ (NAT GW only; Phase 2 adds second AZ for Suricata Ingress IPS)
  subnet_cidr_public_ingress = ["10.11.0.0/24"]

  # Private App — 3 AZs (EKS: Wazuh, Grafana, Keycloak)
  subnet_cidr_private = ["10.11.5.0/24", "10.11.6.0/24", "10.11.7.0/24"]

  # TGW attachment — /28 per AZ
  subnet_cidr_tgw = ["10.11.240.0/28", "10.11.240.16/28", "10.11.240.32/28"]

  # NAT: 2 NAT GWs (one per public subnet) for HA — only 2 public subnets so per-az is incompatible
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  # Flow Logs
  flowlog_traffic_type         = "ALL"
  flowlog_aggregation_interval = 60

  #--------------------------------------------------------------
  # Transit Gateway — read from local state after tgw apply
  #--------------------------------------------------------------
  tgw_id       = data.terraform_remote_state.tgw.outputs.tgw_id
  tgw_rt_id    = data.terraform_remote_state.tgw.outputs.shared_rt_id
  tgw_spoke_rt = data.terraform_remote_state.tgw.outputs.spoke_rt_id

  # Peer VPC CIDRs
  ctrl_vpc_cidr = "10.0.0.0/16"
  prd_vpc_cidr  = "10.30.0.0/16"

  #--------------------------------------------------------------
  # EKS Cluster — XDR Infrastructure data pipeline
  #
  # This cluster hosts the INGEST and ML pipeline components only.
  # AWS managed services (MSK, Flink, OpenSearch) are separate resources.
  #
  # collector (m6a.large  — 2 vCPU/ 8 GB): nProbe + Vector
  # ml        (g4dn.xlarge — 4 vCPU/16 GB + GPU, SPOT): Triton Inference Server
  # cti       (m6a.xlarge — 4 vCPU/16 GB): MISP + OpenCTI + AI investigation
  #--------------------------------------------------------------
  eks_cluster_name            = "${local.platform_name}-${local.env}-eks"
  eks_cluster_version         = "1.34"
  eks_endpoint_public_access  = false
  eks_endpoint_private_access = true
  eks_enable_irsa             = true
  eks_deletion_protection     = false

  eks_node_group_defaults = {
    ami_type       = "AL2023_x86_64_STANDARD"
    capacity_type  = "ON_DEMAND"
    instance_types = ["m6a.large"]
  }

  eks_node_groups = {
    # nProbe (VPC Flow Log / IPFIX collector) + Vector (logs, Falco, DNS, Auth, GuardDuty)
    collector = {
      min_size       = 1
      max_size       = 4
      desired_size   = 1
      instance_types = ["m6a.large"]
      labels         = { "role" = "collector" }
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

    # Triton Inference Server — T1: LightGBM, T2: CNN-MLP, GNN, Autoencoder, DGA, Behavioral
    # Spot GPU — scales to 0 when inference queue is empty
    ml = {
      min_size       = 0
      max_size       = 3
      desired_size   = 0
      capacity_type  = "SPOT"
      instance_types = ["g4dn.xlarge", "g4dn.2xlarge"]
      ami_type       = "AL2023_x86_64_NVIDIA"
      labels         = { "role" = "ml-inference" }
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
      taints = {
        gpu = {
          key    = "nvidia.com/gpu"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }
    }

    # MISP + OpenCTI (threat intel) + AI investigation (self-hosted LLM fallback)
    cti = {
      min_size       = 1
      max_size       = 4
      desired_size   = 1
      instance_types = ["m6a.xlarge"]
      labels         = { "role" = "cti" }
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
            volume_size           = 150
            volume_type           = "gp3"
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
      taints = {
        dedicated = {
          key    = "dedicated"
          value  = "cti"
          effect = "NO_SCHEDULE"
        }
      }
    }
  }

  #--------------------------------------------------------------
  # EKS Addons
  #--------------------------------------------------------------
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

#--------------------------------------------------------------
# TGW remote state — local backend, populated after tgw apply
# Deploy order: shared/transit-gateway → bc-xdr → bc-ctrl → bc-prd
#--------------------------------------------------------------
data "terraform_remote_state" "tgw" {
  backend = "s3"
  config = {
    bucket = "bc-uatms-terraform-state"
    key    = "shared/transit-gateway/terraform.tfstate"
    region = "eu-central-1"
  }
}

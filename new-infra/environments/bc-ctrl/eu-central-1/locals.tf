locals {
  #--------------------------------------------------------------
  # General
  #--------------------------------------------------------------
  company       = "big-chemistry"
  env           = "ctrl"
  platform_name = "bc"
  customer_name = "Big Chemistry"
  region        = "eu-central-1"

  common_tags = {
    Customer     = local.customer_name
    Environment  = local.env
    Confidential = "yes"
    IACTool      = "Terraform"
    VPCRole      = "control-plane"
  }

  #--------------------------------------------------------------
  # Networking — Control Plane VPC
  #--------------------------------------------------------------
  vpc_cidr           = "10.0.0.0/16"
  availability_zones = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]

  subnet_cidr_public  = ["10.0.0.0/24"]
  subnet_cidr_private = ["10.0.10.0/24", "10.0.11.0/24", "10.0.12.0/24"]
  subnet_cidr_tgw     = ["10.0.240.0/28", "10.0.240.16/28", "10.0.240.32/28"]

  single_nat_gateway     = true   # test only — 1 EIP (EIP quota is tight in this account)
  one_nat_gateway_per_az = false

  flowlog_traffic_type         = "ALL"
  flowlog_aggregation_interval = 60

  #--------------------------------------------------------------
  # Transit Gateway
  #--------------------------------------------------------------
  tgw_id       = data.terraform_remote_state.tgw.outputs.tgw_id
  tgw_rt_id    = data.terraform_remote_state.tgw.outputs.shared_rt_id
  tgw_spoke_rt = data.terraform_remote_state.tgw.outputs.spoke_rt_id

  xdr_vpc_cidr = "10.11.0.0/16"
  prd_vpc_cidr = "10.30.0.0/16"

  #--------------------------------------------------------------
  # EKS Cluster — Control Plane (response/orchestration layer)
  #
  # This cluster hosts all detection response and orchestration services.
  #
  # security (m6a.xlarge — 4 vCPU/16 GB): Wazuh Manager 3-node HA, Shuffle SOAR, DFIR-IRIS
  # platform (m6a.large  — 2 vCPU/ 8 GB): Enforcement API, Cilium Operator, Grafana,
  #                                         Kibana, Keycloak, Kyverno, Trivy/Sigstore
  #--------------------------------------------------------------
  eks_cluster_name            = "${local.platform_name}-${local.env}-eks"
  eks_cluster_version         = "1.35"
  eks_endpoint_public_access  = false
  eks_endpoint_private_access = true
  eks_enable_irsa             = true
  eks_deletion_protection     = true
  deploy_security_helm        = false # set true when applying from within VPC

  eks_node_group_defaults = {
    ami_type       = "AL2023_x86_64_STANDARD"
    capacity_type  = "ON_DEMAND"
    instance_types = ["m6a.large"]
  }

  eks_node_groups = {
    # Wazuh Manager 3-node HA (~4-6 GB each), Shuffle SOAR, DFIR-IRIS case management
    security = {
      min_size       = 2
      max_size       = 6
      desired_size   = 2
      instance_types = ["m6a.xlarge"]
      labels         = { "role" = "security" }
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
        dedicated = {
          key    = "dedicated"
          value  = "security"
          effect = "NO_SCHEDULE"
        }
      }
    }

    # Enforcement API (FastAPI + Celery + boto3/WAF/NFW workers), Cilium Operator,
    # Grafana, Kibana, Keycloak, Kyverno (3 replicas), Trivy + Sigstore webhooks
    platform = {
      min_size       = 2
      max_size       = 6
      desired_size   = 2
      instance_types = ["m6a.large"]
      labels         = { "role" = "platform" }
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

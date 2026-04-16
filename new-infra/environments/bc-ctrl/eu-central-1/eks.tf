#--------------------------------------------------------------
# bc-ctrl EKS Cluster — hosts Wazuh Manager / Indexer / Dashboard
#
# Network:
#   Private subnets only (10.0.10.0/24, eu-central-1a).
#   Egress via fck-nat instance (ECR pulls, Helm chart downloads).
#
# Endpoint access:
#   Public  = true  → CI (ubuntu-latest) can kubectl apply Wazuh manifests
#   Private = true  → self-hosted runner in bc-ctrl VPC uses private path
#
# Node group — security (t3.xlarge × 2–3):
#   Wazuh Indexer (OpenSearch) requests 8 Gi per pod × 3 replicas = 24 Gi
#   minimum. t3.xlarge = 16 GB. 2 nodes gives 32 GB usable (after OS
#   overhead) — fits indexer + manager + dashboard with headroom.
#
# Extra node SG rules:
#   bc-prd (10.30.0.0/16) → 1514 (events) + 1515 (enrollment)
#   Wazuh agents in bc-prd reach Manager via VPC peering →
#   internal NLB (created by AWS LBC from manager/service.yaml).
#
# NOTE: Uses eks module ~> 21.0 (bc-ctrl AWS provider >= 6.23).
# v21 renamed several arguments vs v20 (used in bc-prd):
#   cluster_name    → name
#   cluster_version → kubernetes_version
#   cluster_endpoint_public_access  → endpoint_public_access
#   cluster_endpoint_private_access → endpoint_private_access
#   cluster_addons  → addons
#   cluster_security_group_additional_rules → renamed (drop cluster_ prefix; NOT auto-managed)
#--------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "${local.platform_name}-${local.env}-eks"
  kubernetes_version = "1.35"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  endpoint_public_access  = true  # CI public runner needs this for kubectl apply
  endpoint_private_access = true  # Self-hosted runner uses private path

  # Disable auto-permissions to prevent 409 conflicts
  enable_cluster_creator_admin_permissions = false

  access_entries = {
    matei = {
      principal_arn = "arn:aws:iam::286439316079:user/Matei"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    afonso = {
      principal_arn = "arn:aws:iam::286439316079:user/Afonso"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    gh_deploy = {
      principal_arn = "arn:aws:iam::286439316079:role/GitHubActionsDeployRole"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    runner = {
      principal_arn = "arn:aws:iam::286439316079:role/github-runner-role"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  node_security_group_additional_rules = {
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    # Wazuh agents in bc-prd reach Manager via VPC peering - internal NLB - node
    ingress_prd_wazuh_events = {
      description = "bc-prd Wazuh agents to Manager events (1514)"
      protocol    = "tcp"
      from_port   = 1514
      to_port     = 1514
      type        = "ingress"
      cidr_blocks = [local.prd_vpc_cidr]
    }
    ingress_prd_wazuh_enroll = {
      description = "bc-prd Wazuh agents to Manager enrollment (1515)"
      protocol    = "tcp"
      from_port   = 1515
      to_port     = 1515
      type        = "ingress"
      cidr_blocks = [local.prd_vpc_cidr]
    }
    egress_all = {
      description = "Node all egress"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "egress"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  security_group_additional_rules = {
    ingress_nodes_443 = {
      description                = "Nodes to cluster API"
      protocol                   = "tcp"
      from_port                  = 443
      to_port                    = 443
      type                       = "ingress"
      source_node_security_group = true
    }
  }

  addons = {
    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true  # Must be present before node bootstrap
    }  # required for Pod Identity (LBC, ext-secrets)
    coredns                = { most_recent = true }
    kube-proxy             = { most_recent = true }
    vpc-cni = {
      most_recent    = true
      before_compute = true  # CNI must exist before nodes boot; without this, NetworkPluginNotReady
      configuration_values = jsonencode({
        env = {
          # EXTERNALSNAT=true: pod traffic SNAT'd to node IP → fck-nat handles egress
          AWS_VPC_K8S_CNI_EXTERNALSNAT = "true"
        }
      })
    }
  }

  eks_managed_node_groups = {
    security = {
      instance_types = ["t3.xlarge"]
      min_size       = 2
      max_size       = 3
      desired_size   = 2
      labels         = { role = "security" }
    }
  }

  tags = local.common_tags
}

#--------------------------------------------------------------
# EKS Addons — AWS LBC + external-secrets + cert-manager + external-dns
#
# AWS LBC:          creates internal NLB for wazuh-manager Service
# external-secrets: syncs AWS Secrets Manager → K8s Secrets (Wazuh creds)
# cert-manager:     issues TLS certs for Wazuh Indexer inter-node comms
# external-dns:     writes wazuh-manager.bc-ctrl.internal → NLB DNS
#                   into the Route53 private zone (route53.tf)
#--------------------------------------------------------------
module "eks_addons" {
  source = "../../../modules/eks-addons"

  cluster_name                       = module.eks.cluster_name
  cluster_endpoint                   = module.eks.cluster_endpoint
  cluster_certificate_authority_data = module.eks.cluster_certificate_authority_data
  oidc_provider_arn                  = module.eks.oidc_provider_arn
  vpc_id                             = module.vpc.vpc_id
  region                             = local.region

  deploy_helm_releases             = true
  install_load_balancer_controller = true
  install_external_secrets         = true
  install_cert_manager             = true
  install_external_dns             = true

  # Scope external-dns to bc-ctrl.internal zone only
  external_dns_route53_zone_arns = [aws_route53_zone.bc_ctrl_internal.arn]
  external_dns_domain_filter     = "bc-ctrl.internal"

  # bc-ctrl has one node group — no dedicated "platform" taint
  platform_node_label = { role = "security" }

  tags = local.common_tags
}

#--------------------------------------------------------------
# Outputs
#--------------------------------------------------------------
output "eks_cluster_name" {
  value = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "eks_cluster_security_group_id" {
  value = module.eks.cluster_security_group_id
}

#--------------------------------------------------------------
# bc-ctrl EKS Cluster — hosts Falco / Cilium / Tetragon
#
# Wazuh and MISP migrated to bare EC2 (wazuh-ec2.tf, vm.tf).
#
# Network:
#   Private subnets only (10.0.10.0/24, eu-central-1a).
#   Egress via fck-nat instance (ECR pulls, Helm chart downloads).
#
# Endpoint access:
#   Public  = true  → CI runner can kubectl apply
#   Private = true  → self-hosted runner in bc-ctrl VPC uses private path
#
# Node group — security (t3.medium × 1–2):
#   Falco + Cilium + Tetragon only — no heavy stateful workloads.
#
# NOTE: Uses eks module ~> 21.0 (bc-ctrl AWS provider >= 6.23).
#--------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 21.0"

  name               = "${local.platform_name}-${local.env}-eks"
  kubernetes_version = "1.35"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  endpoint_public_access  = true # CI public runner needs this for kubectl apply
  endpoint_private_access = true # Self-hosted runner uses private path

  # Disable auto-permissions to prevent 409 conflicts
  enable_cluster_creator_admin_permissions = false

  # Pin KMS admin to CI role so local plans don't flip-flop the policy on apply
  kms_key_administrators = ["arn:aws:iam::286439316079:role/GitHubActionsDeployRole"]

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
    coredns    = { most_recent = true }
    kube-proxy = { most_recent = true }
    vpc-cni = {
      most_recent    = true
      before_compute = true # CNI must exist before nodes boot; without this, NetworkPluginNotReady
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
      instance_types = ["t3.medium"]
      min_size       = 1
      max_size       = 2
      desired_size   = 2
      disk_size      = 30
      labels         = { role = "security" }
    }
  }

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

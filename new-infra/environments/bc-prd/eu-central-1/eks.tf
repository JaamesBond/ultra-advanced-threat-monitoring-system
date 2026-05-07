module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = "${local.platform_name}-${local.env}-eks"
  cluster_version = "1.35"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnet_ids

  cluster_endpoint_public_access  = true # Keep true until Helm is done
  cluster_endpoint_private_access = true

  # CRITICAL: Disable auto-permissions to prevent 409 conflicts in the pipeline
  enable_cluster_creator_admin_permissions = false

  # Pin KMS admin to CI role so local plans don't flip-flop the policy on apply
  kms_key_administrators = ["arn:aws:iam::286439316079:role/GitHubActionsDeployRole"]

  access_entries = {
    # 1. Manual entry for local management
    matei = {
      principal_arn     = "arn:aws:iam::286439316079:user/Matei"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    afonso = {
      principal_arn     = "arn:aws:iam::286439316079:user/Afonso"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    # 2. Grant access to the role assumed by GitHub Actions
    gh_deploy = {
      principal_arn     = "arn:aws:iam::286439316079:role/GitHubActionsDeployRole"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    # 3. Grant access to the Runner Instance Profile
    runner = {
      principal_arn     = "arn:aws:iam::286439316079:role/github-runner-role"
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # Add ingress rule to cluster SG for node access (required for Cilium/CoreDNS)
  cluster_security_group_additional_rules = {
    ingress_nodes_443 = {
      description                = "Nodes to cluster API"
      protocol                   = "tcp"
      from_port                  = 443
      to_port                    = 443
      type                       = "ingress"
      source_node_security_group = true
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
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
    }
  }

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
      configuration_values = jsonencode({
        env = {
          AWS_VPC_K8S_CNI_EXTERNALSNAT = "true"
        }
      })
    }
    # aws-ebs-csi-driver = {
    #   most_recent = true
    # }
  }

  eks_managed_node_groups = {
    workload = {
      instance_types = ["t3.medium"]
      min_size     = 2
      max_size     = 2
      desired_size = 2
      labels = {
        role = "workload"
      }
      # iam_role_additional_policies = {
      #   ebs_csi = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      # }
    }
  }

  tags = local.common_tags
}

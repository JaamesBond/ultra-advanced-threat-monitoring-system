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

  # Cluster was created with bootstrap_self_managed_addons=false (Cilium handles CNI/proxy).
  # Pin to false to prevent module v20.37+ from force-replacing the cluster on its default of true.
  bootstrap_self_managed_addons = false

  # Pin KMS admin to CI role so local plans don't flip-flop the policy on apply
  kms_key_administrators = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/GitHubActionsDeployRole"]

  access_entries = {
    # 1. Manual entry for local management
    matei = {
      principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/Matei"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    afonso = {
      principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:user/Afonso"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    # 2. Grant access to the role assumed by GitHub Actions
    gh_deploy = {
      principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/GitHubActionsDeployRole"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
    # 3. Grant access to the Runner Instance Profile
    runner = {
      principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/github-runner-role"
      policy_associations = {
        admin = {
          policy_arn   = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
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
      description = "Node all egress"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "egress"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }

  cluster_addons = {
    coredns = {
      most_recent = true
    }
    # kube-proxy removed — Phase G: Cilium kubeProxyReplacement takes over service routing.
    vpc-cni = {
      most_recent    = true
      before_compute = true  # install CNI before node groups join so nodes start Ready (cold-start race fix)
      configuration_values = jsonencode({
        env = {
          AWS_VPC_K8S_CNI_EXTERNALSNAT = "true"
        }
      })
    }
    aws-ebs-csi-driver = {
      most_recent              = true
      service_account_role_arn = aws_iam_role.ebs_csi.arn
    }
    aws-efs-csi-driver = {
      most_recent              = true
      service_account_role_arn = aws_iam_role.efs_csi.arn
    }
  }

  eks_managed_node_groups = {
    workload = {
      instance_types = ["t3.medium"]
      min_size       = 2
      max_size       = 2
      desired_size   = 2
      labels = {
        role = "workload"
      }
      iam_role_additional_policies = {
        ebs_csi = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
      }
    }

    # Dedicated node pool for NOMAD Oasis — observation target for the security stack only.
    # t3.large is sufficient: NOMAD runs as a passive workload target, not a real research load.
    # Single node (min=max=desired=1) reduces cost from ~$243/mo to ~$60/mo.
    # Taint dedicated=nomad:NoSchedule keeps Falco/Cilium/Tetragon DaemonSets off this pool
    # (they don't carry this toleration). NOMAD Helm release must set the matching toleration.
    nomad = {
      ami_type       = "AL2023_x86_64_STANDARD"
      instance_types = ["t3.large"]
      min_size       = 1
      max_size       = 1
      desired_size   = 1
      labels = {
        role = "nomad"
      }
      taints = [
        {
          key    = "dedicated"
          value  = "nomad"
          effect = "NO_SCHEDULE"
        }
      ]
      iam_role_additional_policies = {
        ebs_csi = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
        efs_csi = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
      }
    }
  }

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# IRSA role — EBS CSI driver
# ---------------------------------------------------------------------------
resource "aws_iam_role" "ebs_csi" {
  name = "${local.platform_name}-${local.env}-ebs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ---------------------------------------------------------------------------
# IRSA role — EFS CSI driver
# ---------------------------------------------------------------------------
resource "aws_iam_role" "efs_csi" {
  name = "${local.platform_name}-${local.env}-efs-csi"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = module.eks.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${module.eks.oidc_provider}:sub" = "system:serviceaccount:kube-system:efs-csi-controller-sa"
            "${module.eks.oidc_provider}:aud" = "sts.amazonaws.com"
          }
        }
      }
    ]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  role       = aws_iam_role.efs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

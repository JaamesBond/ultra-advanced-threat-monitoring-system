#--------------------------------------------------------------
# TEST VARIANT: EC2 instead of EKS
#
# Replaces the Production Spoke EKS cluster with a single Ubuntu
# EC2 instance for connectivity and TGW routing tests.
#
# Access: SSM Session Manager only (no SSH key, no public IP)
# No public subnet, no IGW — all egress routes via TGW → XDR VPC.
#
# Switch back to EKS once the SCP block on eks:CreateCluster is resolved.
#--------------------------------------------------------------

data "aws_ami" "ubuntu_prd" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

#--------------------------------------------------------------
# IAM — SSM access
#--------------------------------------------------------------

resource "aws_iam_role" "prd_test" {
  name = "bc-prd-test-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = local.common_tags
}

resource "aws_iam_role_policy_attachment" "prd_test_ssm" {
  role       = aws_iam_role.prd_test.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "prd_test" {
  name = "bc-prd-test-profile"
  role = aws_iam_role.prd_test.name
}

#--------------------------------------------------------------
# Security Group — intra-VPC + TGW inbound, egress all
#--------------------------------------------------------------

resource "aws_security_group" "prd_test" {
  name        = "bc-prd-test-sg"
  description = "Production spoke test instance - SSM only, no public ingress"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "All traffic from within VPC"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr]
  }

  ingress {
    description = "Traffic from Control Plane VPC via TGW"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.ctrl_vpc_cidr]
  }

  ingress {
    description = "Traffic from XDR VPC via TGW"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.xdr_vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.common_tags, { Name = "bc-prd-test-sg" })
}

#--------------------------------------------------------------
# EC2 Instance — t3.medium, Ubuntu 24.04, private subnet
# No public route — egress via TGW → XDR NAT GW (validates spoke routing)
#--------------------------------------------------------------

resource "aws_instance" "prd_test" {
  ami                    = data.aws_ami.ubuntu_prd.id
  instance_type          = "t3.medium"
  subnet_id              = module.vpc.private_subnet_ids[0]
  vpc_security_group_ids = [aws_security_group.prd_test.id]
  iam_instance_profile   = aws_iam_instance_profile.prd_test.name

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
    encrypted   = true
  }

  user_data_base64 = base64encode(<<-EOF
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get install -y curl iputils-ping
  EOF
  )

  tags = merge(local.common_tags, { Name = "bc-prd-test" })
}

#--------------------------------------------------------------
# Outputs
#--------------------------------------------------------------

output "prd_test_instance_id" {
  description = "SSM connect: aws ssm start-session --target <id>"
  value       = aws_instance.prd_test.id
}

output "prd_test_private_ip" {
  value = aws_instance.prd_test.private_ip
}

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

  eks_managed_node_groups = local.eks_node_groups

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

#--------------------------------------------------------------
# bc-prd — EKS Addons
#
# Wires the reusable eks-addons module to the bc-prd cluster.
# Installs:
#   - AWS Load Balancer Controller  (internal NLBs for workloads)
#   - external-secrets operator     (sync Secrets Manager → K8s)
#
# cert-manager is NOT deployed here — TLS certificates for
# production workloads are issued by the bc-ctrl cert-manager
# instance and distributed via external-secrets (ClusterSecretStore).
#
# Image pull note: bc-prd has no internet egress. All images are
# pulled through the ECR Pull-Through Cache
# (<account>.dkr.ecr.eu-central-1.amazonaws.com/docker-hub/...).
# Chart images are rendered with the correct registry prefix via
# the image overrides in the eks-addons module.
#
# BLOCKED until EKS cluster exists (same SCP constraint as bc-ctrl).
#--------------------------------------------------------------

#--------------------------------------------------------------
# Providers pointing at the bc-prd cluster
#--------------------------------------------------------------
data "aws_eks_cluster" "this" {
  name = local.eks_cluster_name
}

data "aws_eks_cluster_auth" "this" {
  name = local.eks_cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.this.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.this.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.this.certificate_authority[0].data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

#--------------------------------------------------------------
# Addons
#--------------------------------------------------------------
module "eks_addons" {
  source = "../../../modules/eks-addons"

  cluster_name                       = local.eks_cluster_name
  cluster_endpoint                   = data.aws_eks_cluster.this.endpoint
  cluster_certificate_authority_data = data.aws_eks_cluster.this.certificate_authority[0].data
  oidc_provider_arn                  = data.aws_eks_cluster.this.identity[0].oidc[0].issuer
  vpc_id                             = module.vpc.vpc_id
  region                             = local.region

  install_load_balancer_controller = true
  install_external_secrets         = true
  install_cert_manager             = false  # managed centrally in bc-ctrl

  # bc-prd has no dedicated platform node group — addons run on workload nodes
  platform_node_label = { role = "workload" }

  tags = local.common_tags
}

#--------------------------------------------------------------
# EBS CSI Driver IAM — Pod Identity for ebs-csi-controller-sa
#
# Without this, the controller pod falls back to node role which
# lacks ec2:DescribeAvailabilityZones → addon stays CREATE_FAILED.
#--------------------------------------------------------------
resource "aws_iam_role" "ebs_csi" {
  name        = "${local.platform_name}-${local.env}-ebs-csi-driver"
  description = "Pod Identity role for EBS CSI Driver controller in ${local.env} EKS"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })

  tags = merge(local.common_tags, { Component = "ebs-csi-driver" })
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

resource "aws_eks_pod_identity_association" "ebs_csi" {
  cluster_name    = local.eks_cluster_name
  namespace       = "kube-system"
  service_account = "ebs-csi-controller-sa"
  role_arn        = aws_iam_role.ebs_csi.arn

  tags = merge(local.common_tags, { Component = "ebs-csi-driver" })
}

#--------------------------------------------------------------
# Wazuh Agent IAM — Pod Identity for the DaemonSet in bc-prd
#
# The Agent DaemonSet needs:
#   - SSM read access (to register as a managed instance, optional)
#   - Secrets Manager read for its own enrollment key (bc/wazuh/agent-*)
#   - EC2 describe (node self-enrichment: AZ, instance-id, tags)
#--------------------------------------------------------------
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_iam_policy_document" "wazuh_agent_trust" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
    actions = [
      "sts:AssumeRole",
      "sts:TagSession",
    ]
  }
}

resource "aws_iam_role" "wazuh_agent" {
  name               = "${local.platform_name}-${local.env}-wazuh-agent"
  description        = "Pod Identity role for Wazuh Agent DaemonSet in bc-prd EKS"
  assume_role_policy = data.aws_iam_policy_document.wazuh_agent_trust.json

  tags = merge(local.common_tags, {
    Component = "wazuh-agent"
  })
}

data "aws_iam_policy_document" "wazuh_agent" {
  # Read the enrollment / manager-registration secret
  statement {
    sid    = "ReadAgentSecrets"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:secretsmanager:${local.region}:${data.aws_caller_identity.current.account_id}:secret:bc/wazuh/agent*",
    ]
  }

  # EC2 describe — node self-labelling in agent ossec.conf
  statement {
    sid    = "DescribeEc2Self"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeNetworkInterfaces",
      "ec2:DescribeTags",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "wazuh_agent" {
  name        = "${local.platform_name}-${local.env}-wazuh-agent"
  description = "Permissions for Wazuh Agent DaemonSet pods in bc-prd"
  policy      = data.aws_iam_policy_document.wazuh_agent.json
}

resource "aws_iam_role_policy_attachment" "wazuh_agent" {
  role       = aws_iam_role.wazuh_agent.name
  policy_arn = aws_iam_policy.wazuh_agent.arn
}

resource "aws_eks_pod_identity_association" "wazuh_agent" {
  cluster_name    = local.eks_cluster_name
  namespace       = "wazuh"
  service_account = "wazuh-agent"
  role_arn        = aws_iam_role.wazuh_agent.arn

  tags = merge(local.common_tags, {
    Component = "wazuh-agent"
  })
}

#--------------------------------------------------------------
# Outputs
#--------------------------------------------------------------
output "aws_lb_controller_role_arn" {
  description = "ARN of the AWS Load Balancer Controller IAM role (bc-prd)"
  value       = module.eks_addons.aws_lb_controller_role_arn
}

output "external_secrets_role_arn" {
  description = "ARN of the external-secrets IAM role (bc-prd)"
  value       = module.eks_addons.external_secrets_role_arn
}

output "wazuh_agent_role_arn" {
  description = "IAM role ARN assumed by the Wazuh Agent DaemonSet pods via Pod Identity"
  value       = aws_iam_role.wazuh_agent.arn
}

output "ebs_csi_role_arn" {
  description = "IAM role ARN assumed by the EBS CSI Driver controller via Pod Identity"
  value       = aws_iam_role.ebs_csi.arn
}

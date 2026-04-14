#--------------------------------------------------------------
# bc-ctrl — EKS Addons
#
# Wires the reusable eks-addons module to the bc-ctrl cluster.
# Installs:
#   - AWS Load Balancer Controller (for Wazuh Manager internal NLB)
#   - external-secrets operator     (for wazuh-manager-secrets)
#   - cert-manager                  (for Wazuh Indexer TLS)
#
# BLOCKED until EKS cluster exists. The cluster creation itself
# is currently blocked by the eks:CreateCluster SCP. Once lifted,
# this file can be applied via terraform apply.
#--------------------------------------------------------------

#--------------------------------------------------------------
# Providers pointing at the bc-ctrl cluster
# (assumes the eks module is declared in this workspace;
#  the data sources below read it back from the cluster state)
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
# Import pre-existing IAM resources created before this Terraform
# workspace managed them.
#--------------------------------------------------------------
import {
  to = module.eks_addons.aws_iam_policy.external_dns[0]
  id = "arn:aws:iam::286439316079:policy/bc-ctrl-eks-external-dns"
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
  install_cert_manager             = true
  install_external_dns             = true

  external_dns_route53_zone_arns = [
    "arn:aws:route53:::hostedzone/${aws_route53_zone.internal.zone_id}"
  ]
  external_dns_domain_filter = "bc-ctrl.internal"

  platform_node_label = { role = "platform" }

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
# Outputs
#--------------------------------------------------------------
output "aws_lb_controller_role_arn" {
  description = "ARN of the AWS Load Balancer Controller IAM role (bc-ctrl)"
  value       = module.eks_addons.aws_lb_controller_role_arn
}

output "external_secrets_role_arn" {
  description = "ARN of the external-secrets IAM role (bc-ctrl)"
  value       = module.eks_addons.external_secrets_role_arn
}

output "external_dns_role_arn" {
  description = "ARN of the external-dns IAM role (bc-ctrl)"
  value       = module.eks_addons.external_dns_role_arn
}

output "ebs_csi_role_arn" {
  description = "IAM role ARN assumed by the EBS CSI Driver controller via Pod Identity"
  value       = aws_iam_role.ebs_csi.arn
}

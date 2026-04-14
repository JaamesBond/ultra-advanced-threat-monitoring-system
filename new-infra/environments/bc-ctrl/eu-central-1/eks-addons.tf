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

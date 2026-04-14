#--------------------------------------------------------------
# EKS Addons module — variables
#--------------------------------------------------------------
variable "cluster_name" {
  description = "Name of the EKS cluster"
  type        = string
}

variable "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  type        = string
}

variable "cluster_certificate_authority_data" {
  description = "Base64-encoded CA data for the EKS cluster"
  type        = string
}

variable "oidc_provider_arn" {
  description = "OIDC provider ARN for IRSA (fallback when Pod Identity not used)"
  type        = string
}

variable "vpc_id" {
  description = "VPC ID the cluster runs in (required by AWS LB Controller)"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

#--------------------------------------------------------------
# Helm deployment gate
#
# Set to true only when running from a host with direct connectivity
# to the private EKS API endpoint (e.g. self-hosted runner, bastion,
# or manual apply from within the VPC).
# Leave false (default) for CI runs from the public internet so that
# the helm/kubernetes providers never attempt to connect.
#--------------------------------------------------------------
variable "deploy_helm_releases" {
  description = "Actually install Helm charts. Requires connectivity to the private EKS API endpoint. Set false for public CI runners."
  type        = bool
  default     = false
}

#--------------------------------------------------------------
# Addon toggles
#--------------------------------------------------------------
variable "install_load_balancer_controller" {
  description = "Install AWS Load Balancer Controller (needed for Service type=LoadBalancer → NLB/ALB)"
  type        = bool
  default     = true
}

variable "install_external_secrets" {
  description = "Install external-secrets operator (syncs AWS Secrets Manager → K8s Secrets)"
  type        = bool
  default     = true
}

variable "install_cert_manager" {
  description = "Install cert-manager (TLS cert automation for Wazuh Indexer / internal CA)"
  type        = bool
  default     = true
}

variable "install_external_dns" {
  description = "Install external-dns (writes Route53 records from Service/Ingress annotations)"
  type        = bool
  default     = false
}

#--------------------------------------------------------------
# Chart versions (pinned — no implicit upgrades)
#--------------------------------------------------------------
variable "aws_lb_controller_chart_version" {
  description = "AWS Load Balancer Controller Helm chart version"
  type        = string
  default     = "1.9.2"
}

variable "external_secrets_chart_version" {
  description = "external-secrets operator Helm chart version"
  type        = string
  default     = "0.10.5"
}

variable "cert_manager_chart_version" {
  description = "cert-manager Helm chart version"
  type        = string
  default     = "v1.16.1"
}

variable "external_dns_chart_version" {
  description = "external-dns Helm chart version"
  type        = string
  default     = "1.14.5"
}

variable "external_dns_route53_zone_arns" {
  description = "Route53 hosted zone ARNs that external-dns is allowed to manage (format: arn:aws:route53:::hostedzone/ZXXXXX)"
  type        = list(string)
  default     = []
}

variable "external_dns_domain_filter" {
  description = "DNS domain suffix external-dns watches (e.g. bc-ctrl.internal). Empty = all zones in zone_arns."
  type        = string
  default     = ""
}

#--------------------------------------------------------------
# Scheduling — target the "platform" nodegroup where available
#--------------------------------------------------------------
variable "platform_node_label" {
  description = "Node label selector for platform/addon workloads"
  type        = map(string)
  default     = { role = "platform" }
}

variable "tags" {
  description = "Tags applied to AWS resources created by this module"
  type        = map(string)
  default     = {}
}

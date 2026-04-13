#--------------------------------------------------------------
# EKS Addons module — outputs
#--------------------------------------------------------------
output "aws_lb_controller_role_arn" {
  description = "IAM role ARN used by the AWS Load Balancer Controller pod"
  value       = try(aws_iam_role.aws_lb_controller[0].arn, null)
}

output "external_secrets_role_arn" {
  description = "IAM role ARN used by the external-secrets operator"
  value       = try(aws_iam_role.external_secrets[0].arn, null)
}

output "aws_lb_controller_installed" {
  description = "Whether the AWS Load Balancer Controller was installed"
  value       = var.install_load_balancer_controller
}

output "external_secrets_installed" {
  description = "Whether external-secrets was installed"
  value       = var.install_external_secrets
}

output "cert_manager_installed" {
  description = "Whether cert-manager was installed"
  value       = var.install_cert_manager
}

output "external_dns_role_arn" {
  description = "IAM role ARN used by the external-dns pod"
  value       = try(aws_iam_role.external_dns[0].arn, null)
}

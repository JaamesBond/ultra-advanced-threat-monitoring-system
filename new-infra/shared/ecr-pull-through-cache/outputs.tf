output "docker_hub_prefix" {
  description = "ECR repository prefix for Docker Hub images (use as: <account>.dkr.ecr.<region>.amazonaws.com/docker-hub/<image>:<tag>)"
  value       = aws_ecr_pull_through_cache_rule.docker_hub.ecr_repository_prefix
}

output "quay_prefix" {
  value = aws_ecr_pull_through_cache_rule.quay.ecr_repository_prefix
}

output "ghcr_prefix" {
  value = aws_ecr_pull_through_cache_rule.ghcr.ecr_repository_prefix
}

output "k8s_prefix" {
  value = aws_ecr_pull_through_cache_rule.k8s.ecr_repository_prefix
}

output "ecr_public_prefix" {
  value = aws_ecr_pull_through_cache_rule.ecr_public.ecr_repository_prefix
}

output "docker_hub_credentials_secret_arn" {
  description = "Secrets Manager ARN for Docker Hub credentials — populate with `aws secretsmanager put-secret-value`"
  value       = aws_secretsmanager_secret.docker_hub.arn
}

output "registry_url" {
  description = "Full ECR registry URL for this account/region"
  value       = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.region}.amazonaws.com"
}

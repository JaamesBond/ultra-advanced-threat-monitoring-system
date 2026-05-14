output "vpc_id" {
  value = module.vpc.vpc_id
}

# ---------------------------------------------------------------------------
# ACM — self-signed wildcard cert for *.bc-ctrl.internal (internal ALB)
#
# Consumed by:
#   - pipeline-engineer: pipeline seds this ARN into the Ingress YAML via the
#     same ${AWS_ACCOUNT_ID} substitution pattern used for ECR image refs.
#   - security-stack-engineer: ALB Ingress annotation
#     alb.ingress.kubernetes.io/certificate-arn: <this value>
# ---------------------------------------------------------------------------
output "acm_cert_arn" {
  description = "ARN of the self-signed wildcard ACM cert for *.bc-ctrl.internal — used as alb.ingress.kubernetes.io/certificate-arn on the xdr-shared ALB Ingress"
  value       = aws_acm_certificate.xdr_internal.arn
}

# ---------------------------------------------------------------------------
# EFS — NOMAD Oasis (consumed by security-stack-engineer for StorageClass ref)
# ---------------------------------------------------------------------------
output "nomad_efs_file_system_id" {
  description = "EFS file system ID for NOMAD Oasis -- used in StorageClass and NOMAD Helm values"
  value       = aws_efs_file_system.nomad_oasis.id
}

output "nomad_efs_dns_name" {
  description = "EFS DNS name for direct NFS mounts (format: <fs-id>.efs.eu-central-1.amazonaws.com)"
  value       = aws_efs_file_system.nomad_oasis.dns_name
}

output "nomad_efs_mount_target_dns_names" {
  description = "Per-AZ EFS mount target DNS names (format: <az>.<fs-id>.efs.eu-central-1.amazonaws.com)"
  value = {
    for subnet_id, mt in aws_efs_mount_target.nomad_oasis :
    subnet_id => mt.dns_name
  }
}

# ---------------------------------------------------------------------------
# Secrets Manager ARNs — NOMAD Oasis
# Consumed by:
#   - pipeline-engineer: CI bootstrap step writes values to these ARNs
#   - security-stack-engineer: ExternalSecret CRs reference these paths
# ---------------------------------------------------------------------------
output "nomad_secret_arn_api" {
  description = "ARN of bc/nomad-oasis/api secret"
  value       = aws_secretsmanager_secret.nomad_api.arn
}

output "nomad_secret_arn_mongo" {
  description = "ARN of bc/nomad-oasis/mongo secret"
  value       = aws_secretsmanager_secret.nomad_mongo.arn
}

output "nomad_secret_arn_keycloak" {
  description = "ARN of bc/nomad-oasis/keycloak secret"
  value       = aws_secretsmanager_secret.nomad_keycloak.arn
}

output "nomad_secret_arn_north" {
  description = "ARN of bc/nomad-oasis/north secret"
  value       = aws_secretsmanager_secret.nomad_north.arn
}

output "nomad_secret_arn_datacite" {
  description = "ARN of bc/nomad-oasis/datacite secret"
  value       = aws_secretsmanager_secret.nomad_datacite.arn
}


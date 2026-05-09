# ---------------------------------------------------------------------------
# AWS Secrets Manager shells for NOMAD Oasis
#
# These resources create the secret metadata only — no secret_version blocks.
# Values are populated by the pipeline-engineer's CI bootstrap step, which
# reads from GitHub Secrets and writes to AWS SM via the CLI:
#   aws secretsmanager put-secret-value --secret-id bc/nomad-oasis/api --secret-string ...
#
# Terraform intentionally omits aws_secretsmanager_secret_version blocks so
# that it never overwrites values that CI has already populated. The lifecycle
# prevent_destroy guard protects against accidental `terraform destroy` runs
# removing secrets that hold live credentials.
#
# recovery_window_in_days = 7 (not 0) gives operators a restore window if a
# secret is accidentally deleted.
# ---------------------------------------------------------------------------

locals {
  # Reuse the EKS KMS key for SM encryption — same key used for EBS/EFS,
  # keeps key rotation and audit in one place.
  nomad_sm_kms_key_id = module.eks.kms_key_arn
}

resource "aws_secretsmanager_secret" "nomad_api" {
  name                    = "bc/nomad-oasis/api"
  description             = "NOMAD Oasis API credentials"
  kms_key_id              = local.nomad_sm_kms_key_id
  recovery_window_in_days = 7

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "bc/nomad-oasis/api" })
}

resource "aws_secretsmanager_secret" "nomad_mongo" {
  name                    = "bc/nomad-oasis/mongo"
  description             = "NOMAD Oasis MongoDB credentials"
  kms_key_id              = local.nomad_sm_kms_key_id
  recovery_window_in_days = 7

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "bc/nomad-oasis/mongo" })
}

resource "aws_secretsmanager_secret" "nomad_keycloak" {
  name                    = "bc/nomad-oasis/keycloak"
  description             = "NOMAD Oasis Keycloak admin credentials"
  kms_key_id              = local.nomad_sm_kms_key_id
  recovery_window_in_days = 7

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "bc/nomad-oasis/keycloak" })
}

resource "aws_secretsmanager_secret" "nomad_north" {
  name                    = "bc/nomad-oasis/north"
  description             = "NOMAD Oasis north-API / federation token"
  kms_key_id              = local.nomad_sm_kms_key_id
  recovery_window_in_days = 7

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "bc/nomad-oasis/north" })
}

resource "aws_secretsmanager_secret" "nomad_datacite" {
  name                    = "bc/nomad-oasis/datacite"
  description             = "NOMAD Oasis DataCite DOI credentials (shell only -- may remain unpopulated)"
  kms_key_id              = local.nomad_sm_kms_key_id
  recovery_window_in_days = 7

  lifecycle {
    prevent_destroy = true
  }

  tags = merge(local.common_tags, { Name = "bc/nomad-oasis/datacite" })
}

# ---------------------------------------------------------------------------
# Self-signed wildcard TLS certificate for *.bc-ctrl.internal
#
# Purpose: terminate HTTPS on the internal ALB (xdr-shared group) so
# Keycloak can issue Secure cookies and browsers accept the HTTPS session.
#
# Design decisions:
#   - Self-signed import flow: tls_private_key → tls_self_signed_cert →
#     aws_acm_certificate (import, not DNS/email validation).
#   - Cert lives in bc-prd state because the ALB that uses it lives in bc-prd.
#   - 5-year validity (1825 days) survives cold-start rebuild cycles without
#     needing a rotation plan during dev/testing.
#   - RSA-2048 matches the existing Wazuh pattern in bc-ctrl.
#   - SANs: *.bc-ctrl.internal + bc-ctrl.internal (apex, for any direct hits).
#
# Cold-start safety:
#   - tls_private_key + tls_self_signed_cert regenerate from scratch on any
#     fresh state. Each rebuild produces a new cert/key pair; ACM import
#     creates a new certificate ARN. Helm Ingress annotation references the
#     ARN via the acm_cert_arn output, which the pipeline substitutes via sed.
#   - No ACME challenge or DNS validation record needed — import is instant.
#
# Stage targeting (for pipeline-engineer):
#   All three resources below are Stage 1 targets:
#     -target=tls_private_key.xdr_internal
#     -target=tls_self_signed_cert.xdr_internal
#     -target=aws_acm_certificate.xdr_internal
# ---------------------------------------------------------------------------

resource "tls_private_key" "xdr_internal" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "xdr_internal" {
  private_key_pem = tls_private_key.xdr_internal.private_key_pem

  subject {
    common_name  = "*.bc-ctrl.internal"
    organization = "Big Chemistry UATMS"
  }

  # 5 years — long enough to survive multiple cold-start rebuild cycles without
  # rotation churn. Rotate when the XDR stack moves to a CA-signed cert.
  validity_period_hours = 43800 # 5 * 365 * 24

  # Wildcard + apex SANs so a single cert covers both nomad.bc-ctrl.internal
  # and hubble.bc-ctrl.internal, plus any future *.bc-ctrl.internal services.
  dns_names = [
    "*.bc-ctrl.internal",
    "bc-ctrl.internal",
  ]

  allowed_uses = [
    "digital_signature",
    "key_encipherment",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "xdr_internal" {
  # Import flow — no DNS/email validation required. ACM accepts the cert
  # immediately (no PENDING_VALIDATION state).
  private_key      = tls_private_key.xdr_internal.private_key_pem
  certificate_body = tls_self_signed_cert.xdr_internal.cert_pem

  # On rebuild, create the new cert before destroying the old one so the
  # ALB listener reference is never momentarily invalid.
  lifecycle {
    create_before_destroy = true
  }

  tags = merge(local.common_tags, {
    Name = "xdr-internal-wildcard"
  })
}

# ---------------------------------------------------------------------------
# ALB lookup — used by Route53 ALIAS records below.
#
# The AWS Load Balancer Controller sets this tag on the ALB it provisions
# when an Ingress uses `alb.ingress.kubernetes.io/group.name: xdr-shared`.
# The controller's tagging convention is:
#   ingress.k8s.aws/stack = <group-name>   (when group.name annotation is set)
#
# IMPORTANT: This data source will fail (no results) during Stage 1 because
# the Ingress object and therefore the ALB do not exist yet. The pipeline
# must NOT include this data source or the two aws_route53_record resources
# below in Stage 1 or Stage 2 targets. They are Stage 3a targets:
#   -target=data.aws_lb.xdr_shared
#   -target=aws_route53_record.nomad
#   -target=aws_route53_record.hubble
# ---------------------------------------------------------------------------

data "aws_lb" "xdr_shared" {
  tags = {
    "ingress.k8s.aws/stack" = "xdr-shared"
  }
}

# ---------------------------------------------------------------------------
# Route53 ALIAS records in bc-ctrl.internal
#
# The zone lives in bc-ctrl state; its ID is already exported as:
#   output "route53_bc_ctrl_internal_zone_id"
# The bc-prd state already reads bc-ctrl remote state via
#   data "terraform_remote_state" "ctrl" (in terraform_config.tf).
#
# Both records point at the same internal ALB (group=xdr-shared).
# ALBs always need evaluate_target_health = true for ALIAS records.
# ---------------------------------------------------------------------------

resource "aws_route53_record" "nomad" {
  zone_id = data.terraform_remote_state.ctrl.outputs.route53_bc_ctrl_internal_zone_id
  name    = "nomad.bc-ctrl.internal"
  type    = "A"

  alias {
    name                   = data.aws_lb.xdr_shared.dns_name
    zone_id                = data.aws_lb.xdr_shared.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "hubble" {
  zone_id = data.terraform_remote_state.ctrl.outputs.route53_bc_ctrl_internal_zone_id
  name    = "hubble.bc-ctrl.internal"
  type    = "A"

  alias {
    name                   = data.aws_lb.xdr_shared.dns_name
    zone_id                = data.aws_lb.xdr_shared.zone_id
    evaluate_target_health = true
  }
}

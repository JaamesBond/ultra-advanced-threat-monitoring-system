#--------------------------------------------------------------
# Wazuh Dashboard — TLS certificate for internal ALB
#
# Approach: self-signed cert imported into ACM (free — no Private CA).
# The cert is valid for 10 years. Because it is self-signed, browsers
# accessed from outside the VPN will show an "untrusted issuer" warning;
# add the cert_pem output to your local trust store to suppress it.
#
# The private key is stored in Terraform state (encrypted S3 backend).
# Rotate by tainting both resources and re-applying.
#--------------------------------------------------------------

resource "tls_private_key" "wazuh_dashboard" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "wazuh_dashboard" {
  private_key_pem = tls_private_key.wazuh_dashboard.private_key_pem

  subject {
    common_name  = "wazuh.bc-ctrl.internal"
    organization = "Big Chemistry"
  }

  dns_names = ["wazuh.bc-ctrl.internal"]

  # 10 years — internal cert, no public CA rotation requirement
  validity_period_hours = 87600

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

# Import the self-signed cert into ACM (no per-cert charge for imported certs)
resource "aws_acm_certificate" "wazuh_dashboard" {
  private_key      = tls_private_key.wazuh_dashboard.private_key_pem
  certificate_body = tls_self_signed_cert.wazuh_dashboard.cert_pem

  tags = merge(local.common_tags, {
    Name = "wazuh-dashboard-bc-ctrl-internal"
  })

  lifecycle {
    create_before_destroy = true
  }
}

#--------------------------------------------------------------
# Outputs
#--------------------------------------------------------------
output "wazuh_dashboard_cert_arn" {
  description = "ACM cert ARN for the Wazuh dashboard internal ALB"
  value       = aws_acm_certificate.wazuh_dashboard.arn
}

output "wazuh_dashboard_cert_pem" {
  description = "Self-signed cert PEM — add to your local trust store to silence browser warnings"
  value       = tls_self_signed_cert.wazuh_dashboard.cert_pem
  sensitive   = false
}

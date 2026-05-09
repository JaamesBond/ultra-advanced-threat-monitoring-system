# ---------------------------------------------------------------------------
# ACM Certificate for NOMAD Oasis — DEFERRED (Phase I blocker)
#
# A public ACM certificate + Route53 validation records are required for
# the ALB ingress that will serve the NOMAD Oasis UI and API publicly.
#
# Prerequisite: a public Route53 hosted zone must exist (e.g. nomad.bigchemistry.eu).
# That zone does not yet exist — see Phase I in SECURITY_STACK_ROLLOUT_PLAN.md.
#
# When the public zone is available, add:
#
#   resource "aws_acm_certificate" "nomad_oasis" {
#     domain_name               = "nomad.bigchemistry.eu"
#     subject_alternative_names = ["*.nomad.bigchemistry.eu"]
#     validation_method         = "DNS"
#     tags                      = merge(local.common_tags, { Name = "nomad-oasis" })
#     lifecycle { create_before_destroy = true }
#   }
#
#   resource "aws_route53_record" "nomad_acm_validation" {
#     for_each = {
#       for dvo in aws_acm_certificate.nomad_oasis.domain_validation_options :
#       dvo.domain_name => dvo
#     }
#     zone_id = <public_zone_id>
#     name    = each.value.resource_record_name
#     type    = each.value.resource_record_type
#     records = [each.value.resource_record_value]
#     ttl     = 60
#   }
#
#   resource "aws_acm_certificate_validation" "nomad_oasis" {
#     certificate_arn         = aws_acm_certificate.nomad_oasis.arn
#     validation_record_fqdns = [for r in aws_route53_record.nomad_acm_validation : r.fqdn]
#   }
#
# Until then, NOMAD v1 is accessed via:
#   kubectl port-forward -n nomad svc/nomad-app 8080:80
# The ALB Ingress in the Helm values file must keep ingress.enabled=false.
# ---------------------------------------------------------------------------

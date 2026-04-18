#--------------------------------------------------------------
# Private Hosted Zone — bc-ctrl.internal
#
# Used by:
#   - Wazuh agents in bc-prd resolving wazuh-manager.bc-ctrl.internal
#   - Resources in bc-ctrl resolving misp.bc-ctrl.internal
#
# Must be associated with BOTH VPCs:
#   - bc-ctrl: so resources in this VPC can resolve the zone
#   - bc-prd:  so Wazuh agents in bc-prd can resolve wazuh-manager.*
#--------------------------------------------------------------

resource "aws_route53_zone" "bc_ctrl_internal" {
  name    = "bc-ctrl.internal"
  comment = "Private zone for bc-ctrl services reachable from bc-prd via VPC peering"

  vpc {
    vpc_id     = module.vpc.vpc_id
    vpc_region = local.region
  }

  tags = merge(local.common_tags, {
    Name = "bc-ctrl-internal"
  })
}

# Associate with bc-prd VPC so Wazuh agents can resolve wazuh-manager.bc-ctrl.internal
resource "aws_route53_zone_association" "bc_ctrl_internal_prd" {
  zone_id = aws_route53_zone.bc_ctrl_internal.zone_id
  vpc_id  = data.terraform_remote_state.prd.outputs.vpc_id
}

output "route53_bc_ctrl_internal_zone_id" {
  description = "Route53 private zone ID for bc-ctrl.internal"
  value       = aws_route53_zone.bc_ctrl_internal.zone_id
}

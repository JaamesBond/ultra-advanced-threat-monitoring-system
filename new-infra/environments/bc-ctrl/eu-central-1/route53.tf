#--------------------------------------------------------------
# bc-ctrl — Private DNS zone (bc-ctrl.internal)
#
# Hosts internal records for services living in the control plane
# that must be reachable from other VPCs over the TGW. Today that's
# the Wazuh Manager internal NLB (agents in bc-prd resolve
# wazuh-manager.bc-ctrl.internal → NLB → Manager pods).
#
# The zone is primary-attached to the bc-ctrl VPC and cross-VPC
# associated with bc-prd so Route53 resolver inside bc-prd can
# answer queries for *.bc-ctrl.internal. bc-xdr does not currently
# need to resolve these names but can be added the same way.
#--------------------------------------------------------------

data "terraform_remote_state" "prd" {
  backend = "s3"
  config = {
    bucket = "bc-uatms-terraform-state"
    key    = "environments/bc-prd/terraform.tfstate"
    region = "eu-central-1"
  }
}

data "terraform_remote_state" "xdr" {
  backend = "s3"
  config = {
    bucket = "bc-uatms-terraform-state"
    key    = "environments/bc-xdr/terraform.tfstate"
    region = "eu-central-1"
  }
}

import {
  to = aws_route53_zone.internal
  id = "Z0233517HPLJCOO1NV0L"
}

resource "aws_route53_zone" "internal" {
  name          = "bc-ctrl.internal"
  comment       = "Private zone for Control Plane services (Wazuh NLB, etc.)"
  force_destroy = false

  vpc {
    vpc_id     = module.vpc.vpc_id
    vpc_region = local.region
  }

  # Ignore additional VPC associations created out-of-band below;
  # aws_route53_zone_association manages those separately.
  lifecycle {
    ignore_changes = [vpc]
  }

  tags = merge(local.common_tags, {
    Name      = "bc-ctrl.internal"
    Component = "private-dns"
  })
}

#--------------------------------------------------------------
# Cross-VPC association — bc-prd resolves bc-ctrl.internal
# The bc-prd VPC must authorize this association from its side
# (aws_route53_vpc_association_authorization in bc-prd) OR this
# role must have cross-account permissions. Since both VPCs live
# in the same account here, a direct association is sufficient.
#--------------------------------------------------------------
import {
  to = aws_route53_zone_association.prd
  id = "Z0233517HPLJCOO1NV0L:vpc-05cd97059433a569a"
}

resource "aws_route53_zone_association" "prd" {
  zone_id    = aws_route53_zone.internal.zone_id
  vpc_id     = data.terraform_remote_state.prd.outputs.vpc_id
  vpc_region = local.region
}

# bc-xdr association — required for the Wazuh Agent on bc-xdr-test EC2
# to resolve wazuh-manager.bc-ctrl.internal → Manager NLB.
resource "aws_route53_zone_association" "xdr" {
  zone_id    = aws_route53_zone.internal.zone_id
  vpc_id     = data.terraform_remote_state.xdr.outputs.vpc_id
  vpc_region = local.region
}

#--------------------------------------------------------------
# wazuh-manager.bc-ctrl.internal record
#
# Managed automatically by external-dns running in bc-ctrl EKS.
# When the AWS Load Balancer Controller creates the internal NLB
# from k8s/wazuh/manager/service.yaml, external-dns sees the
# annotation:
#   external-dns.alpha.kubernetes.io/hostname: wazuh-manager.bc-ctrl.internal
# and upserts the CNAME into this zone. No manual Terraform record
# or variable needed.
#--------------------------------------------------------------

#--------------------------------------------------------------
# Outputs
#--------------------------------------------------------------
output "internal_zone_id" {
  description = "Route53 private zone ID for bc-ctrl.internal"
  value       = aws_route53_zone.internal.zone_id
}

output "internal_zone_name" {
  value = aws_route53_zone.internal.name
}

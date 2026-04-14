#--------------------------------------------------------------
# XDR Infrastructure VPC  (10.11.0.0/16 — Option A)
#
# Purpose: All security tooling — Wazuh Manager/Indexer, Zeek, Suricata,
#          MISP, Grafana, Loki, Prometheus, Keycloak.
#
# Security posture:
#   - Public Ingress subnets (2 AZs): Phase 2 — Suricata Ingress IPS HA pair
#   - Inspection subnets (2 AZs): Phase 2 — Suricata Egress, NAT VM, Zeek, Forwarding Appliance
#     Phase 1 interim routing: 0.0.0.0/0 → NAT GW (updated in Phase 2)
#   - Management subnet (1 AZ): MISP, Bastion (SSM-only)
#   - Private App subnets (3 AZs): EKS — Wazuh, Grafana, Keycloak
#   - Data subnets (3 AZs): OpenSearch/Wazuh Indexer, Loki storage
#   - TGW attachment subnets (3 AZs): TGW ENIs
#
# TGW: appliance_mode = ENABLE — critical for inline Zeek/Suricata.
#   Without appliance mode, TGW can load-balance a 5-tuple flow across
#   ENIs in different AZs, breaking symmetric inspection on the IPS pair.
#
# This environment also creates the spoke-rt static default route
#   (0.0.0.0/0 → this XDR attachment) which forces all Production VPC
#   internet egress through XDR for inspection.
#--------------------------------------------------------------

module "vpc" {
  source = "../../../modules/network/vpc"

  vpc_name           = "${local.platform_name}-${local.env}-vpc"
  cidr_block         = local.vpc_cidr
  availability_zones = local.availability_zones

  # Public Ingress — 1 AZ (NAT GW; Phase 2 adds second AZ for Suricata Ingress IPS)
  public_subnet_cidrs   = local.subnet_cidr_public_ingress
  # Private App — 3 AZs (EKS: Wazuh, Grafana, Keycloak)
  private_subnet_cidrs  = local.subnet_cidr_private
  # TGW attachment — 3 AZs, /28
  intra_subnet_cidrs    = local.subnet_cidr_tgw

  create_igw             = true
  enable_nat_gateway     = true
  single_nat_gateway     = local.single_nat_gateway
  one_nat_gateway_per_az = local.one_nat_gateway_per_az

  enable_flow_log                   = true
  flow_log_traffic_type             = local.flowlog_traffic_type
  flow_log_max_aggregation_interval = local.flowlog_aggregation_interval
  flow_log_retention_in_days        = local.cloudwatch_log_files_retention

  tags = local.common_tags
}

#--------------------------------------------------------------
# VPC Endpoints — keep AWS API traffic off internet
# Secrets Manager enabled here (Wazuh credentials, Keycloak secrets)
#--------------------------------------------------------------
module "vpc_endpoints" {
  source = "../../../modules/network/vpc/endpoints"

  name_prefix    = "${local.platform_name}-${local.env}"
  region         = local.region
  vpc_id         = module.vpc.vpc_id
  vpc_cidr_block = module.vpc.vpc_cidr_block

  private_subnet_ids      = module.vpc.private_subnet_ids
  private_route_table_ids = module.vpc.private_route_table_ids
  intra_route_table_ids   = module.vpc.intra_route_table_ids

  enable_s3              = true
  enable_ecr_api         = true
  enable_ecr_dkr         = true
  enable_ssm             = true
  enable_cloudwatch_logs = true
  enable_kms             = true
  enable_sts             = true
  enable_secretsmanager  = true  # Wazuh/Keycloak credentials

  tags = local.common_tags
}

#--------------------------------------------------------------
# Transit Gateway Attachment
# APPLIANCE MODE = ENABLE — mandatory for inline Zeek/Suricata inspection
#--------------------------------------------------------------
resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = local.tgw_id
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.intra_subnet_ids

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  # CRITICAL: prevents asymmetric routing across AZs for the same 5-tuple flow
  appliance_mode_support = "enable"
  dns_support            = "enable"

  tags = merge(local.common_tags, {
    Name = "${local.platform_name}-${local.env}-tgw-attachment"
  })
}

# Associate XDR attachment with shared-services route table
resource "aws_ec2_transit_gateway_route_table_association" "shared" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = local.tgw_rt_id
}

# Propagate XDR routes into shared-rt (ctrl can reach xdr, xdr can reach ctrl)
resource "aws_ec2_transit_gateway_route_table_propagation" "to_shared" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = local.tgw_rt_id
}

# Propagate XDR routes into spoke-rt — spokes need to return traffic to XDR VPC
resource "aws_ec2_transit_gateway_route_table_propagation" "to_spoke" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = local.tgw_spoke_rt
}

# CRITICAL static route: all spoke internet egress → XDR Infrastructure VPC
# This forces Production VPC (and future spokes) to route 0.0.0.0/0 through
# XDR for Suricata/Zeek inspection before reaching the internet.
resource "aws_ec2_transit_gateway_route" "spoke_default_via_xdr" {
  destination_cidr_block         = "0.0.0.0/0"
  transit_gateway_route_table_id = local.tgw_spoke_rt
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
}

#--------------------------------------------------------------
# Return routes on PUBLIC subnet route table
# NAT GW lives in the public subnet. After de-NAT, response packets
# have a spoke destination (10.30.x.x). Without this route the
# packet hits 0.0.0.0/0 → IGW, which drops private IPs.
#--------------------------------------------------------------
resource "aws_route" "public_to_prd" {
  count = length(module.vpc.public_route_table_ids)

  route_table_id         = module.vpc.public_route_table_ids[count.index]
  destination_cidr_block = local.prd_vpc_cidr
  transit_gateway_id     = local.tgw_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

#--------------------------------------------------------------
# Cross-VPC routes on private subnet route tables
# (vpc module already adds 0.0.0.0/0 → NAT GW for private subnets)
#--------------------------------------------------------------
# Phase 1 interim: spoke internet egress via NAT GW (bypasses inspection)
# Traffic from prd arrives at intra subnets via TGW — needs a default route
# to NAT GW so it can reach the internet. Phase 2 replaces this with
# inspection-subnet routing (Suricata/Zeek inline).
resource "aws_route" "intra_default_via_nat" {
  count = length(module.vpc.intra_route_table_ids)

  route_table_id         = module.vpc.intra_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = module.vpc.nat_gateway_ids[0]

  depends_on = [module.vpc]
}

resource "aws_route" "private_to_ctrl" {
  count = length(module.vpc.private_route_table_ids)

  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = local.ctrl_vpc_cidr
  transit_gateway_id     = local.tgw_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

resource "aws_route" "private_to_prd" {
  count = length(module.vpc.private_route_table_ids)

  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = local.prd_vpc_cidr
  transit_gateway_id     = local.tgw_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

#--------------------------------------------------------------
# Outputs
#--------------------------------------------------------------
output "vpc_id" {
  value = module.vpc.vpc_id
}

output "vpc_cidr_block" {
  value = module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  value = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  value = module.vpc.public_subnet_ids
}

output "nat_gateway_ids" {
  value = module.vpc.nat_gateway_ids
}

output "tgw_attachment_id" {
  description = "XDR TGW attachment ID — referenced by spoke-rt static default route"
  value       = aws_ec2_transit_gateway_vpc_attachment.this.id
}

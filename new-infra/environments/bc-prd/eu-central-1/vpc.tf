#--------------------------------------------------------------
# Production Spoke VPC  (10.30.0.0/16)
#
# Purpose: Production application workloads with zero internet exposure.
#          Test environment for validating TGW routing and XDR telemetry
#          before rolling out to additional spoke VPCs.
#
# Security posture:
#   - ZERO public subnets — no IGW, no NAT Gateway
#   - All internet egress routes via TGW → XDR Infrastructure VPC
#     (XDR's TGW spoke-rt static 0.0.0.0/0 → XDR attachment enforces this)
#   - Private App subnets: EKS workloads, Wazuh agents (port 1514/1515 → XDR)
#   - Data subnets: fully isolated (no default route, only local VPC traffic)
#   - VPC Endpoints: AWS API calls remain on private network (no NAT needed)
#
# Wazuh telemetry flow:
#   Production pod → private subnet RT (0.0.0.0/0 → TGW) → TGW spoke-rt
#   → XDR attachment → XDR Private App subnet → Wazuh Manager (port 1514)
#
# Note: The explicit 10.11.0.0/16 route is technically covered by the
#   0.0.0.0/0 → TGW route, but is kept explicit for clarity and to ensure
#   Wazuh agent traffic is not accidentally blocked by a future default route
#   change.
#--------------------------------------------------------------

module "vpc" {
  source = "../../../modules/network/vpc"

  vpc_name           = "${local.platform_name}-${local.env}-vpc"
  cidr_block         = local.vpc_cidr
  availability_zones = local.availability_zones

  # No public subnets — zero internet exposure
  public_subnet_cidrs  = []
  private_subnet_cidrs = local.subnet_cidr_private
  intra_subnet_cidrs   = local.subnet_cidr_tgw

  # No IGW and no NAT — all egress via TGW
  create_igw         = false
  enable_nat_gateway = false
  single_nat_gateway = false

  enable_flow_log                   = true
  flow_log_traffic_type             = local.flowlog_traffic_type
  flow_log_max_aggregation_interval = local.flowlog_aggregation_interval
  flow_log_retention_in_days        = local.cloudwatch_log_files_retention

  tags = local.common_tags
}

#--------------------------------------------------------------
# VPC Endpoints — AWS API calls without internet/NAT dependency
# Interface endpoints placed in private subnets so EKS pods
# can reach ECR, SSM, KMS, etc. without leaving the VPC.
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
  enable_ssm             = true   # SSM Session Manager for node access
  enable_cloudwatch_logs = true
  enable_kms             = true
  enable_sts             = true
  enable_secretsmanager  = false

  tags = local.common_tags
}

#--------------------------------------------------------------
# Transit Gateway Attachment — Production → spoke-rt
# spoke-rt has static 0.0.0.0/0 → XDR attachment (created in bc-xdr vpc.tf)
#--------------------------------------------------------------
resource "aws_ec2_transit_gateway_vpc_attachment" "this" {
  transit_gateway_id = local.tgw_id
  vpc_id             = module.vpc.vpc_id
  subnet_ids         = module.vpc.intra_subnet_ids

  transit_gateway_default_route_table_association = false
  transit_gateway_default_route_table_propagation = false

  appliance_mode_support = "disable"
  dns_support            = "enable"

  tags = merge(local.common_tags, {
    Name = "${local.platform_name}-${local.env}-tgw-attachment"
  })
}

# Associate with spoke-rt (not shared-rt — production is a spoke, not core infra)
resource "aws_ec2_transit_gateway_route_table_association" "spoke" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = local.tgw_rt_id
}

# Propagate prd routes into spoke-rt (other spokes can reach prd — adjust if isolation needed)
resource "aws_ec2_transit_gateway_route_table_propagation" "to_spoke" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = local.tgw_rt_id
}

# Propagate prd routes into shared-rt so ctrl + xdr can reach prd for management/telemetry
resource "aws_ec2_transit_gateway_route_table_propagation" "to_shared" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = local.tgw_shared_rt
}

#--------------------------------------------------------------
# Routes: private subnets → TGW for ALL traffic
# No NAT GW exists here — TGW is the sole egress point.
# TGW spoke-rt then routes 0.0.0.0/0 to XDR for inspection.
#--------------------------------------------------------------

# Default route — all internet-bound traffic goes to TGW (then XDR inspection)
resource "aws_route" "private_default_via_tgw" {
  count = length(module.vpc.private_route_table_ids)

  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  transit_gateway_id     = local.tgw_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# Explicit route to XDR VPC — Wazuh agent (1514/1515), Keycloak auth, log shipping
resource "aws_route" "private_to_xdr" {
  count = length(module.vpc.private_route_table_ids)

  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = local.xdr_vpc_cidr
  transit_gateway_id     = local.tgw_id

  depends_on = [aws_ec2_transit_gateway_vpc_attachment.this]
}

# Explicit route to Control Plane VPC — CI/CD, EKS API, management access
resource "aws_route" "private_to_ctrl" {
  count = length(module.vpc.private_route_table_ids)

  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = local.ctrl_vpc_cidr
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

output "tgw_attachment_id" {
  value = aws_ec2_transit_gateway_vpc_attachment.this.id
}

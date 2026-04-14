#--------------------------------------------------------------
# Control Plane VPC  (10.0.0.0/16)
#
# Purpose: CI/CD pipelines, Terraform execution, EKS management plane,
#          admin bastion, CloudTrail aggregation, SSO/IAM Identity Center.
#
# Security posture:
#   - Public subnets hold NAT GWs only (no workloads exposed to internet)
#   - Private subnets use NAT GW for own internet egress
#   - Data subnets are isolated (no default route)
#   - All cross-VPC traffic routes via TGW (explicit routes per peer CIDR)
#   - appliance_mode = disable (ctrl plane is not an inline inspection hop)
#--------------------------------------------------------------

module "vpc" {
  source = "../../../modules/network/vpc"

  vpc_name           = "${local.platform_name}-${local.env}-vpc"
  cidr_block         = local.vpc_cidr
  availability_zones = local.availability_zones

  public_subnet_cidrs   = local.subnet_cidr_public
  private_subnet_cidrs  = local.subnet_cidr_private
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
# VPC Endpoints — AWS API traffic stays on private network
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

  enable_ec2             = true   # nodeadm calls EC2:DescribeInstances during EKS node bootstrap
  enable_s3              = true
  enable_ecr_api         = true
  enable_ecr_dkr         = true
  enable_ssm             = true   # Session Manager access without public bastion
  enable_cloudwatch_logs = true
  enable_kms             = true
  enable_sts             = true
  enable_secretsmanager  = true   # Wazuh Manager + external-secrets operator read bc/* secrets

  tags = local.common_tags
}

#--------------------------------------------------------------
# Transit Gateway Attachment — Control Plane → shared-rt
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

# Associate this attachment with the shared-services route table
resource "aws_ec2_transit_gateway_route_table_association" "shared" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = local.tgw_rt_id
}

# Propagate ctrl VPC routes into shared-rt so XDR + prd can reach ctrl
resource "aws_ec2_transit_gateway_route_table_propagation" "to_shared" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = local.tgw_rt_id
}

# Also propagate into spoke-rt so Production VPC can reach Control Plane
resource "aws_ec2_transit_gateway_route_table_propagation" "to_spoke" {
  transit_gateway_attachment_id  = aws_ec2_transit_gateway_vpc_attachment.this.id
  transit_gateway_route_table_id = local.tgw_spoke_rt
}

#--------------------------------------------------------------
# Cross-VPC routes on private subnet route tables
# (private subnets already have 0.0.0.0/0 → NAT GW from the vpc module)
#--------------------------------------------------------------
resource "aws_route" "private_to_xdr" {
  count = length(module.vpc.private_route_table_ids)

  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = local.xdr_vpc_cidr
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

output "tgw_attachment_id" {
  description = "TGW attachment ID — used by bc-xdr to propagate routes back to ctrl"
  value       = aws_ec2_transit_gateway_vpc_attachment.this.id
}

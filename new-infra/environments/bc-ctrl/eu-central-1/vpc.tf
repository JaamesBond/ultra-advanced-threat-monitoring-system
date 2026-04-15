#--------------------------------------------------------------
# Control Plane VPC (10.0.0.0/16)
#
# Single public subnet — runner VM has public IP + EIP, no NAT needed.
# VPC peering to bc-prd so the runner can reach the private EKS API.
#--------------------------------------------------------------

module "vpc" {
  source = "../../../modules/network/vpc"

  vpc_name           = "${local.platform_name}-${local.env}-vpc"
  cidr_block         = local.vpc_cidr
  availability_zones = local.availability_zones

  public_subnet_cidrs  = local.subnet_cidr_public
  private_subnet_cidrs = local.subnet_cidr_private

  create_igw         = true
  enable_nat_gateway = false

  enable_flow_log                   = true
  flow_log_traffic_type             = local.flowlog_traffic_type
  flow_log_max_aggregation_interval = local.flowlog_aggregation_interval
  flow_log_retention_in_days        = local.cloudwatch_log_files_retention

  tags = local.common_tags
}

#--------------------------------------------------------------
# VPC Endpoints — SSM + Secrets Manager access from private subnet
#--------------------------------------------------------------
module "vpc_endpoints" {
  source = "../../../modules/network/vpc/endpoints"

  name_prefix    = "${local.platform_name}-${local.env}"
  region         = local.region
  vpc_id         = module.vpc.vpc_id
  vpc_cidr_block = module.vpc.vpc_cidr_block

  private_subnet_ids      = module.vpc.private_subnet_ids
  private_route_table_ids = module.vpc.private_route_table_ids
  intra_route_table_ids   = []

  enable_ssm            = true
  enable_secretsmanager = true
  enable_s3             = true
  enable_sts            = true

  tags = local.common_tags
}

#--------------------------------------------------------------
# VPC Peering — ctrl (requester) → prd (accepter)
# Same account + region → auto-accept on accepter side.
#--------------------------------------------------------------
resource "aws_vpc_peering_connection" "ctrl_to_prd" {
  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = data.terraform_remote_state.prd.outputs.vpc_id
  auto_accept = false

  tags = merge(local.common_tags, { Name = "bc-ctrl-to-bc-prd" })
}

# Route: ctrl private subnet → prd CIDR via peering
resource "aws_route" "private_to_prd" {
  count = length(module.vpc.private_route_table_ids)

  route_table_id            = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block    = local.prd_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.ctrl_to_prd.id
}

# Route: public subnet → prd CIDR via peering (runner is in public subnet)
resource "aws_route" "public_to_prd" {
  count = length(module.vpc.public_route_table_ids)

  route_table_id            = module.vpc.public_route_table_ids[count.index]
  destination_cidr_block    = local.prd_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.ctrl_to_prd.id
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

output "peering_connection_id" {
  description = "VPC peering connection ID — bc-prd reads this to accept"
  value       = aws_vpc_peering_connection.ctrl_to_prd.id
}

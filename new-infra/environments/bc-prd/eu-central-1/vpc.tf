#--------------------------------------------------------------
# Production VPC (10.30.0.0/16)
#
# Private subnet only. No IGW, no NAT.
# AWS API via VPC endpoints. Cross-VPC via peering with bc-ctrl.
# bc-ctrl runner reaches EKS private API over peering connection.
#--------------------------------------------------------------

module "vpc" {
  source = "../../../modules/network/vpc"

  vpc_name           = "${local.platform_name}-${local.env}-vpc"
  cidr_block         = local.vpc_cidr
  availability_zones = local.availability_zones

  public_subnet_cidrs  = []
  private_subnet_cidrs = local.subnet_cidr_private

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
# VPC Endpoints — EKS nodes reach ECR, SSM, KMS, etc. privately
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

  enable_ec2             = true
  enable_s3              = true
  enable_ecr_api         = true
  enable_ecr_dkr         = true
  enable_ssm             = true
  enable_cloudwatch_logs = true
  enable_kms             = true
  enable_sts             = true
  enable_secretsmanager  = false

  tags = local.common_tags
}

#--------------------------------------------------------------
# VPC Peering — accept connection from bc-ctrl
#--------------------------------------------------------------
resource "aws_vpc_peering_connection_accepter" "prd_accepts_ctrl" {
  vpc_peering_connection_id = data.terraform_remote_state.ctrl.outputs.peering_connection_id
  auto_accept               = true

  tags = merge(local.common_tags, { Name = "bc-prd-accepts-bc-ctrl" })
}

# Route: prd private subnet → ctrl CIDR via peering
resource "aws_route" "private_to_ctrl" {
  count = length(module.vpc.private_route_table_ids)

  route_table_id            = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block    = local.ctrl_vpc_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.prd_accepts_ctrl.id
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

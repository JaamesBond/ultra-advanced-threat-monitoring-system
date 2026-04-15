#--------------------------------------------------------------
# XDR Infrastructure VPC (10.11.0.0/16)
#
# VPC + subnets only. No TGW — connectivity to bc-ctrl / bc-prd
# is not required in the current minimum-compute phase.
# Existing SIEM EC2 (i-04450a1e86a66a1b3) lives in the public subnet.
#--------------------------------------------------------------

module "vpc" {
  source = "../../../modules/network/vpc"

  vpc_name           = "${local.platform_name}-${local.env}-vpc"
  cidr_block         = local.vpc_cidr
  availability_zones = local.availability_zones

  public_subnet_cidrs  = local.subnet_cidr_public_ingress
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
# VPC Endpoints — keep AWS API traffic off internet
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

  enable_s3              = true
  enable_ecr_api         = true
  enable_ecr_dkr         = true
  enable_ssm             = true
  enable_cloudwatch_logs = true
  enable_kms             = true
  enable_sts             = true
  enable_secretsmanager  = true

  tags = local.common_tags
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

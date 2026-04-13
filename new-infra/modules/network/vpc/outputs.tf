output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "vpc_arn" {
  description = "VPC ARN"
  value       = module.vpc.vpc_arn
}

output "vpc_cidr_block" {
  description = "VPC CIDR block"
  value       = module.vpc.vpc_cidr_block
}

output "igw_id" {
  description = "Internet Gateway ID (null if create_igw = false)"
  value       = try(module.vpc.igw_id, null)
}

# ---- Subnet IDs ----

output "public_subnet_ids" {
  description = "IDs of public subnets"
  value       = module.vpc.public_subnets
}

output "private_subnet_ids" {
  description = "IDs of private subnets"
  value       = module.vpc.private_subnets
}

output "database_subnet_ids" {
  description = "IDs of database/data-tier subnets"
  value       = module.vpc.database_subnets
}

output "intra_subnet_ids" {
  description = "IDs of intra (TGW attachment) subnets"
  value       = module.vpc.intra_subnets
}

# ---- Subnet CIDRs ----

output "public_subnet_cidrs" {
  value = module.vpc.public_subnets_cidr_blocks
}

output "private_subnet_cidrs" {
  value = module.vpc.private_subnets_cidr_blocks
}

output "database_subnet_cidrs" {
  value = module.vpc.database_subnets_cidr_blocks
}

# ---- Route Table IDs ----

output "public_route_table_ids" {
  value = module.vpc.public_route_table_ids
}

output "private_route_table_ids" {
  value = module.vpc.private_route_table_ids
}

output "database_route_table_ids" {
  value = try(module.vpc.database_route_table_ids, [])
}

output "intra_route_table_ids" {
  description = "Route table IDs for TGW attachment subnets"
  value       = try(module.vpc.intra_route_table_ids, [])
}

# ---- NAT / Flow Logs ----

output "nat_gateway_ids" {
  value = module.vpc.natgw_ids
}

output "nat_public_ips" {
  value = module.vpc.nat_public_ips
}

output "flow_log_id" {
  value = try(module.vpc.vpc_flow_log_id, null)
}

# ---- Convenience objects (used by TGW route resources) ----

output "private_subnet_objects" {
  description = "List of {id, cidr_block} for private subnets"
  value = [
    for i, id in module.vpc.private_subnets : {
      id         = id
      cidr_block = module.vpc.private_subnets_cidr_blocks[i]
    }
  ]
}

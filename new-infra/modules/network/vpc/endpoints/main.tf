#--------------------------------------------------------------
# VPC Endpoints
#
# S3 and DynamoDB use Gateway endpoints (free, no ENI).
# All others use Interface endpoints (have ENIs in private subnets).
#
# Interface endpoints share a single security group that allows
# HTTPS inbound from the VPC CIDR only.
#--------------------------------------------------------------

locals {
  # Interface endpoints to create — driven by boolean flags
  interface_endpoints = {
    for k, v in {
      ecr_api            = { name = "com.amazonaws.${var.region}.ecr.api",            enabled = var.enable_ecr_api }
      ecr_dkr            = { name = "com.amazonaws.${var.region}.ecr.dkr",            enabled = var.enable_ecr_dkr }
      ssm                = { name = "com.amazonaws.${var.region}.ssm",                enabled = var.enable_ssm }
      ssm_messages       = { name = "com.amazonaws.${var.region}.ssmmessages",        enabled = var.enable_ssm }
      ec2_messages       = { name = "com.amazonaws.${var.region}.ec2messages",        enabled = var.enable_ssm }
      cloudwatch_logs    = { name = "com.amazonaws.${var.region}.logs",               enabled = var.enable_cloudwatch_logs }
      kms                = { name = "com.amazonaws.${var.region}.kms",                enabled = var.enable_kms }
      sts                = { name = "com.amazonaws.${var.region}.sts",                enabled = var.enable_sts }
      secretsmanager     = { name = "com.amazonaws.${var.region}.secretsmanager",     enabled = var.enable_secretsmanager }
    } : k => v if v.enabled
  }
}

# Security group shared by all interface endpoints
resource "aws_security_group" "endpoints" {
  name        = "${var.name_prefix}-vpc-endpoints-sg"
  description = "Allow HTTPS from VPC CIDR to interface VPC endpoints"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr_block]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpc-endpoints-sg" })
}

# S3 Gateway endpoint — free, no ENI, attaches to route tables
resource "aws_vpc_endpoint" "s3" {
  count = var.enable_s3 ? 1 : 0

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(var.private_route_table_ids, var.intra_route_table_ids)

  tags = merge(var.tags, { Name = "${var.name_prefix}-s3-endpoint" })
}

# DynamoDB Gateway endpoint — free, no ENI
resource "aws_vpc_endpoint" "dynamodb" {
  count = var.enable_dynamodb ? 1 : 0

  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = concat(var.private_route_table_ids, var.intra_route_table_ids)

  tags = merge(var.tags, { Name = "${var.name_prefix}-dynamodb-endpoint" })
}

# Interface endpoints (ECR, SSM, CloudWatch, KMS, STS, Secrets Manager)
resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = var.vpc_id
  service_name        = each.value.name
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-${replace(each.key, "_", "-")}-endpoint" })
}

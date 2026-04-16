module "vpc" {
  source = "../../../modules/network/vpc"

  vpc_name           = "${local.platform_name}-${local.env}-vpc"
  cidr_block         = local.vpc_cidr
  availability_zones = local.azs

  public_subnet_cidrs  = [cidrsubnet(local.vpc_cidr, 8, 0), cidrsubnet(local.vpc_cidr, 8, 1)]
  private_subnet_cidrs = [cidrsubnet(local.vpc_cidr, 8, 10), cidrsubnet(local.vpc_cidr, 8, 11)]

  enable_nat_gateway = false
  create_igw         = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = local.common_tags
}

# fck-nat for PRD (Direct internet egress for nodes)
resource "aws_security_group" "fck_nat_prd" {
  name        = "fck-nat-prd-sg"
  description = "Allow all from internal CIDRs"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [local.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

resource "aws_instance" "fck_nat_prd" {
  ami                         = "ami-077be74ead50d19aa" # fck-nat ARM64 eu-central-1
  instance_type               = "t4g.nano"
  subnet_id                   = module.vpc.public_subnet_ids[0]
  associate_public_ip_address = true
  source_dest_check           = false
  vpc_security_group_ids      = [aws_security_group.fck_nat_prd.id]

  # IP Forwarding and Masquerade
  user_data = <<-EOF
              #!/bin/bash
              echo 1 > /proc/sys/net/ipv4/ip_forward
              iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
              EOF

  tags = merge(local.common_tags, { Name = "fck-nat-prd" })
}

# Route private traffic to local fck-nat
resource "aws_route" "private_nat_prd" {
  count                  = length(module.vpc.private_route_table_ids)
  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.fck_nat_prd.primary_network_interface_id
}

# VPC Endpoints for Private EKS joining (Back up path)
module "vpc_endpoints" {
  source = "../../../modules/network/vpc/endpoints"

  name_prefix        = "${local.platform_name}-${local.env}"
  vpc_id             = module.vpc.vpc_id
  region             = local.region
  vpc_cidr_block     = module.vpc.vpc_cidr_block
  private_subnet_ids = module.vpc.private_subnet_ids
  private_route_table_ids = module.vpc.private_route_table_ids

  enable_s3              = true
  enable_ec2             = true
  enable_ecr_api         = true
  enable_ecr_dkr         = true
  enable_sts             = true
  enable_ssm             = true
  enable_cloudwatch_logs = true
  enable_kms             = true

  tags = local.common_tags
}

# Peering Requester (PRD -> CTRL)
module "peering" {
  source = "../../../modules/network/vpc_peering"

  is_requester    = true
  vpc_id          = module.vpc.vpc_id
  peer_vpc_id     = "vpc-086616521c45f63be" # bc-ctrl-vpc
  peering_name    = "prd-to-ctrl"
  route_table_ids = module.vpc.private_route_table_ids
  peer_cidr_block = "10.0.0.0/16"
  tags            = local.common_tags
}

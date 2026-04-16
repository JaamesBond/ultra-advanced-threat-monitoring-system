module "vpc" {
  source = "../../../modules/network/vpc"

  vpc_name           = "${local.platform_name}-${local.env}-vpc"
  cidr_block         = local.vpc_cidr
  availability_zones = local.azs

  public_subnet_cidrs  = [cidrsubnet(local.vpc_cidr, 8, 0)]
  private_subnet_cidrs = [cidrsubnet(local.vpc_cidr, 8, 10)]

  enable_nat_gateway = false # Using fck-nat

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = local.common_tags
}

# Peering Accepter (CTRL accepts PRD)
module "peering" {
  source = "../../../modules/network/vpc_peering"

  is_requester          = false
  peering_connection_id = data.terraform_remote_state.prd.outputs.peering_id
  peering_name          = "ctrl-accepts-prd"
  route_table_ids       = concat(module.vpc.public_route_table_ids, module.vpc.private_route_table_ids)
  peer_cidr_block       = "10.30.0.0/16"
  tags                  = local.common_tags
}

# fck-nat (Shared for both VPCs)
resource "aws_security_group" "fck_nat" {
  name        = "fck-nat-sg"
  description = "Allow all from internal CIDRs"
  vpc_id      = module.vpc.vpc_id

  ingress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["10.0.0.0/8"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = local.common_tags
}

resource "aws_instance" "fck_nat" {
  ami                         = "ami-077be74ead50d19aa" # fck-nat ARM64 eu-central-1
  instance_type               = "t4g.nano"
  subnet_id                   = module.vpc.public_subnet_ids[0]
  associate_public_ip_address = true
  source_dest_check           = false
  vpc_security_group_ids      = [aws_security_group.fck_nat.id]
  iam_instance_profile        = aws_iam_instance_profile.fck_nat.name

  # Ensure MASQUERADE for the peering VPC
  user_data = <<-EOF
              #!/bin/bash
              echo 1 > /proc/sys/net/ipv4/ip_forward
              iptables -t nat -A POSTROUTING -s 10.30.0.0/16 -o eth0 -j MASQUERADE
              EOF

  tags = merge(local.common_tags, { Name = "fck-nat-shared" })
}

resource "aws_iam_role" "fck_nat" {
  name = "fck-nat-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "fck_nat_ssm" {
  role       = aws_iam_role.fck_nat.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "fck_nat" {
  name = "fck-nat-profile"
  role = aws_iam_role.fck_nat.name
}

# Routes in bc-ctrl private RT to use fck-nat for internet
resource "aws_route" "private_nat" {
  route_table_id         = module.vpc.private_route_table_ids[0]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.fck_nat.primary_network_interface_id
}

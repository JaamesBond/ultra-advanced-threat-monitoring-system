#--------------------------------------------------------------
# fck-nat — ARM64 NAT instance (bc-xdr)
#
# Replaces the managed NAT Gateway (~$32/month) with a community
# NAT instance (~$3.50/month). t4g.nano is ARM64 — matches the
# fck-nat-al2023-*-arm64-ebs AMI.
#
# source_dest_check = false is mandatory: without it the instance
# drops forwarded packets (not the original source IP).
#
# Routes: replace the vpc module's 0.0.0.0/0 → nat-gateway entries
# on all 3 private route tables (enable_nat_gateway = false removes
# the module-managed routes; these fill the gap).
#
# Note: bc-prd internet egress routes via TGW → this XDR VPC.
# This fck-nat instance is the final internet hop for ALL bc-prd
# traffic after Suricata/Zeek inline inspection.
#--------------------------------------------------------------

data "aws_ami" "fck_nat" {
  most_recent = true
  owners      = ["568608671756"]

  filter {
    name   = "name"
    values = ["fck-nat-al2023-*-arm64-ebs"]
  }
}

resource "aws_security_group" "fck_nat" {
  name        = "${local.platform_name}-${local.env}-fck-nat"
  description = "fck-nat: inbound from VPC CIDR, unrestricted outbound"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "All traffic from VPC"
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

  tags = merge(local.common_tags, { Name = "${local.platform_name}-${local.env}-fck-nat" })
}

resource "aws_instance" "fck_nat" {
  ami                         = data.aws_ami.fck_nat.id
  instance_type               = "t4g.nano"
  subnet_id                   = module.vpc.public_subnet_ids[0]
  associate_public_ip_address = true
  source_dest_check           = false

  vpc_security_group_ids = [aws_security_group.fck_nat.id]

  tags = merge(local.common_tags, { Name = "${local.platform_name}-${local.env}-fck-nat" })
}

resource "aws_route" "private_nat" {
  count = length(module.vpc.private_route_table_ids)

  route_table_id         = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block = "0.0.0.0/0"
  network_interface_id   = aws_instance.fck_nat.primary_network_interface_id
}

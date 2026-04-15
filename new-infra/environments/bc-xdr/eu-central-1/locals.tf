locals {
  #--------------------------------------------------------------
  # General
  #--------------------------------------------------------------
  company       = "big-chemistry"
  env           = "xdr"
  platform_name = "bc"
  customer_name = "Big Chemistry"
  region        = "eu-central-1"

  common_tags = {
    Customer     = local.customer_name
    Environment  = local.env
    Confidential = "yes"
    IACTool      = "Terraform"
    VPCRole      = "xdr-infrastructure"
  }

  #--------------------------------------------------------------
  # Networking — XDR Infrastructure VPC
  #
  # CIDR 10.11.0.0/16 in this fresh env.
  # (In the final multi-account design this becomes 10.10.0.0/16)
  #--------------------------------------------------------------
  vpc_cidr           = "10.11.0.0/16"
  # Single AZ — no EKS, just SIEM EC2 + fck-nat
  availability_zones = ["eu-central-1a"]

  # Public — 1 AZ: fck-nat instance
  subnet_cidr_public_ingress = ["10.11.0.0/24"]

  # Private — 1 AZ: SIEM EC2 (Zeek + Suricata)
  subnet_cidr_private = ["10.11.5.0/24"]

  # NAT: fck-nat instance in public subnet (fck-nat.tf)
  single_nat_gateway     = false
  one_nat_gateway_per_az = false

  # Flow Logs
  flowlog_traffic_type         = "ALL"
  flowlog_aggregation_interval = 60

  # Peer VPC CIDRs
  ctrl_vpc_cidr = "10.0.0.0/16"
  prd_vpc_cidr  = "10.30.0.0/16"
}

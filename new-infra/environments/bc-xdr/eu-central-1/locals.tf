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
  availability_zones = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]

  # Public Ingress — 1 AZ (NAT GW only; Phase 2 adds second AZ for Suricata Ingress IPS)
  subnet_cidr_public_ingress = ["10.11.0.0/24"]

  # Private App — 3 AZs (EKS: Wazuh, Grafana, Keycloak)
  subnet_cidr_private = ["10.11.5.0/24", "10.11.6.0/24", "10.11.7.0/24"]

  # TGW attachment — /28 per AZ
  subnet_cidr_tgw = ["10.11.240.0/28", "10.11.240.16/28", "10.11.240.32/28"]

  # NAT: 2 NAT GWs (one per public subnet) for HA — only 2 public subnets so per-az is incompatible
  single_nat_gateway     = true
  one_nat_gateway_per_az = false

  # Flow Logs
  flowlog_traffic_type         = "ALL"
  flowlog_aggregation_interval = 60

  #--------------------------------------------------------------
  # Transit Gateway — read from local state after tgw apply
  #--------------------------------------------------------------
  tgw_id       = data.terraform_remote_state.tgw.outputs.tgw_id
  tgw_rt_id    = data.terraform_remote_state.tgw.outputs.shared_rt_id
  tgw_spoke_rt = data.terraform_remote_state.tgw.outputs.spoke_rt_id

  # Peer VPC CIDRs
  ctrl_vpc_cidr = "10.0.0.0/16"
  prd_vpc_cidr  = "10.30.0.0/16"

}

#--------------------------------------------------------------
# TGW remote state — local backend, populated after tgw apply
# Deploy order: shared/transit-gateway → bc-xdr → bc-ctrl → bc-prd
#--------------------------------------------------------------
data "terraform_remote_state" "tgw" {
  backend = "s3"
  config = {
    bucket = "bc-uatms-terraform-state"
    key    = "shared/transit-gateway/terraform.tfstate"
    region = "eu-central-1"
  }
}

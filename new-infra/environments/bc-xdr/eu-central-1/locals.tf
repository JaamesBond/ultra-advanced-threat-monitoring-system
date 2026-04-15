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
  #--------------------------------------------------------------
  vpc_cidr           = "10.11.0.0/16"
  availability_zones = ["eu-central-1a", "eu-central-1b", "eu-central-1c"]

  subnet_cidr_public_ingress = ["10.11.0.0/24"]
  subnet_cidr_private        = ["10.11.5.0/24", "10.11.6.0/24", "10.11.7.0/24"]

  flowlog_traffic_type         = "ALL"
  flowlog_aggregation_interval = 60
}

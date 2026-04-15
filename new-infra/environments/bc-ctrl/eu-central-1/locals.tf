locals {
  #--------------------------------------------------------------
  # General
  #--------------------------------------------------------------
  company       = "big-chemistry"
  env           = "ctrl"
  platform_name = "bc"
  customer_name = "Big Chemistry"
  region        = "eu-central-1"

  common_tags = {
    Customer     = local.customer_name
    Environment  = local.env
    Confidential = "yes"
    IACTool      = "Terraform"
    VPCRole      = "control-plane"
  }

  #--------------------------------------------------------------
  # Networking — Control Plane VPC
  #--------------------------------------------------------------
  vpc_cidr           = "10.0.0.0/16"
  availability_zones = ["eu-central-1a"]

  subnet_cidr_public  = ["10.0.0.0/24"]
  subnet_cidr_private = ["10.0.10.0/24"]

  prd_vpc_cidr = "10.30.0.0/16"

  flowlog_traffic_type         = "ALL"
  flowlog_aggregation_interval = 60

  #--------------------------------------------------------------
  # Runner VM
  #--------------------------------------------------------------
  github_owner = "JaamesBond"
  github_repo  = "ultra-advanced-threat-monitoring-system"
}

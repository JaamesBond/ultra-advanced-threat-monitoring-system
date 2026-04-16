locals {
  region        = "eu-central-1"
  company       = "big-chemistry"
  env           = "ctrl"
  platform_name = "bc-uatms"

  vpc_cidr     = "10.0.0.0/16"
  prd_vpc_cidr = "10.30.0.0/16"  # bc-prd — Wazuh agents connect via VPC peering
  azs          = ["eu-central-1a", "eu-central-1b"]  # EKS requires 2+ AZs

  common_tags = {
    Project     = "UATMS"
    Environment = local.env
    Customer    = "Big Chemistry"
    IACTool     = "Terraform"
  }

}

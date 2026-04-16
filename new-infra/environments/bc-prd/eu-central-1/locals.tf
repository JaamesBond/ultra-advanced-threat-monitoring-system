locals {
  region        = "eu-central-1"
  company       = "big-chemistry"
  env           = "prd"
  platform_name = "bc-uatms"

  vpc_cidr = "10.30.0.0/16"
  azs      = ["eu-central-1a", "eu-central-1b"]

  common_tags = {
    Project     = "UATMS"
    Environment = local.env
    Customer    = "Big Chemistry"
    IACTool     = "Terraform"
  }
}

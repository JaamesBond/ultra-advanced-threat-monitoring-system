locals {
  region        = "eu-central-1"
  company       = "big-chemistry"
  env           = "ctrl"
  platform_name = "bc-uatms"

  vpc_cidr = "10.0.0.0/16"
  azs      = ["eu-central-1a"]

  common_tags = {
    Project     = "UATMS"
    Environment = local.env
    Customer    = "Big Chemistry"
    IACTool     = "Terraform"
  }
}

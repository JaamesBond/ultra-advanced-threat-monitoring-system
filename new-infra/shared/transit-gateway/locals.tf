locals {
  name_prefix = "bc"
  region      = "eu-central-1"

  common_tags = {
    Customer     = "Big Chemistry"
    Environment  = "shared"
    Confidential = "yes"
    IACTool      = "Terraform"
    Component    = "transit-gateway"
  }
}

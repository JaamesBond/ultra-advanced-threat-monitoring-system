locals {
  region      = "eu-central-1"
  name_prefix = "bc-github-runner"

  common_tags = {
    Customer     = "Big Chemistry"
    Component    = "github-runner"
    Confidential = "yes"
    IACTool      = "Terraform"
  }

  #--------------------------------------------------------------
  # Single runner in bc-ctrl VPC.
  # Labels include bc-prd so this runner handles both ctrl and prd
  # Terraform jobs. It reaches bc-prd EKS via VPC peering.
  #--------------------------------------------------------------
  runners = {
    ctrl = {
      vpc_state_key = "environments/bc-ctrl/terraform.tfstate"
      labels        = "self-hosted,linux,bc-ctrl,bc-prd"
    }
  }

  github_owner = "JaamesBond"
  github_repo  = "ultra-advanced-threat-monitoring-system"
}

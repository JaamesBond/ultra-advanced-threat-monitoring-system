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
  # Runner instances — one per VPC that needs K8s API access
  #
  # Each runner registers with GitHub using a PAT stored in
  # Secrets Manager at bc/github/runner-pat. The user data
  # script fetches it at boot, requests a registration token,
  # and installs the runner as a systemd service.
  #--------------------------------------------------------------
  runners = {
    ctrl = {
      vpc_state_key = "environments/bc-ctrl/terraform.tfstate"
      labels        = "self-hosted,linux,bc-ctrl"
    }
    prd = {
      vpc_state_key = "environments/bc-prd/terraform.tfstate"
      labels        = "self-hosted,linux,bc-prd"
    }
  }

  # GitHub repo where the runner registers
  github_owner = "JaamesBond"
  github_repo  = "ultra-advanced-threat-monitoring-system"
}

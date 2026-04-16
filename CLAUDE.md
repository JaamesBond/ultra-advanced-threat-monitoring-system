# Claude Development Guidelines - XDR v8

## Project: Big Chemistry XDR "Brain/Data" System
Architecture: 2-VPC hub-spoke via Peering (Brain: bc-ctrl, Data: bc-prd).

## Build & Deploy
- **Step 1 (Ctrl)**: `cd new-infra/environments/bc-ctrl/eu-central-1 && terraform apply`
- **Step 2 (Prd)**: `cd new-infra/environments/bc-prd/eu-central-1 && terraform apply`
- **K8s Verification**: `aws eks update-kubeconfig --name bc-uatms-prd-eks && kubectl get nodes`

## Architecture Specs
- **VPC CIDRs**: `bc-ctrl: 10.0.0.0/16`, `bc-prd: 10.30.0.0/16`
- **Compute**:
    - **Worker Nodes**: Strictly 2x `t3.small` in `bc-prd`.
    - **NAT**: 1x `fck-nat` (`t4g.nano`) per VPC.
    - **Runner**: 1x `t3.small` in `bc-ctrl`.
- **Stack**: Cilium, Falco, Tetragon on EKS v1.35.

## Design Principles
1. **Cost-First**: No Managed NAT, No TGW, minimal instance types only.
2. **Brain/Data Split**: All security management tools live in `bc-ctrl`.
3. **No Transitive Routing**: Peerings do not hop; use local egress where needed.
4. **Agentic Deployment**: Automated retry on Helm timeouts; verify node registration first.

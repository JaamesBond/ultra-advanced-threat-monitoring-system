# Claude Development Guidelines - XDR v8

## Project Overview
Architecture: 2-VPC hub-spoke via Peering (Brain: bc-ctrl, Data: bc-prd).

## 🚨 Critical AI Guardrails
- **Mandatory Stack**: Every EKS cluster MUST run Cilium, Falco, and Tetragon. No exceptions.
- **No Transitive Routing**: VPC Peering DOES NOT support internet egress through a peer. `bc-prd` MUST have its own `fck-nat` for worker node internet access.
- **EKS Access Management**: NEVER use `enable_cluster_creator_admin_permissions`. It causes 409 conflicts between local and CI/CD runs. ALWAYS use explicit `access_entries`.
- **Node Capacity**: Worker nodes MUST be `t3.medium`. `t3.small` will fail due to the pod limit (11) being exceeded by the eBPF stack.
- **Runner Support**: The self-hosted runner needs `nodejs`, `git`, `jq`, `libicu`, `terraform`, and `kubectl`.

## Build & Deploy
- **Step 1 (Ctrl)**: `cd new-infra/environments/bc-ctrl/eu-central-1 && terraform apply`
- **Step 2 (Prd)**: `cd new-infra/environments/bc-prd/eu-central-1 && terraform apply`

## Security Stack Verification
- **Falco**: `kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco`
- **Cilium**: `kubectl -n kube-system exec ds/cilium -- cilium status`
- **Tetragon**: `kubectl -n kube-system logs ds/tetragon -c export-stdout`

## Configuration & Policies
- **Network Policies**: Use `CiliumNetworkPolicy` CRDs.
- **Enforcement**: Use `TracingPolicy` CRDs for Tetragon SIGKILL rules.
- **Runtime Rules**: Update `falco_rules.local.yaml` via Helm values.

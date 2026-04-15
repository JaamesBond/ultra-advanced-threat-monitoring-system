# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## MANDATORY SESSION RULES (enforce every response, no exceptions)

### 1. Caveman mode — ALWAYS ON, ULTRA level
Every session starts with caveman ultra. No revert. No drift. Commands stay exact. Drop all filler, articles, hedging. `/caveman ultra` is the baseline — never use normal mode unless user says "stop caveman".

### 2. graphify — query BEFORE acting, update AFTER changing

**Before exploring or modifying anything:**
```bash
# Query graph first — don't read files blindly
/graphify query "<what you need to understand>"
# or trace a path
/graphify path "ConceptA" "ConceptB"
```

**After ANY file change (Terraform, docs, configs):**
```bash
/graphify new-infra --update
```
This re-extracts only changed files. Fast. No excuse to skip.

**If graph missing (fresh clone / graphify-out deleted):**
```bash
/graphify new-infra
```
Full rebuild. Do this before anything else in a new session if `graphify-out/graph.json` absent.

**Graph outputs:** `graphify-out/graph.html` (browser), `graphify-out/GRAPH_REPORT.md` (audit), `graphify-out/graph.json` (raw).

### 3. Keep CLAUDE.md current — update on every architectural change
Any change to: VPC CIDRs, module structure, deploy order, EKS state, TGW routing, CI config → update this file immediately. Architecture drift = bug.

### 4. Always use relative paths
All paths in code, docs, commands, and this file must be relative to the repo root. Never write absolute paths — anyone cloning the repo must be able to use them without modification.

---

## What this is

Terraform infrastructure for **Big Chemistry's XDR v7 threat monitoring system** — two AWS VPCs connected via direct VPC peering, with bc-prd running EKS + Cilium/Tetragon/Falco security stack.

Region: `eu-central-1`. S3 state bucket: `bc-uatms-terraform-state`.

## Deployment order

```bash
# 1. bc-ctrl (VPC + peering requester + runner VM) — pure AWS API, ubuntu-latest
cd new-infra/environments/bc-ctrl/eu-central-1 && terraform init && terraform apply

# 2. Wait ~240s for runner VM to boot and register with GitHub

# 3. bc-prd (EKS + Cilium + policies) — runs on self-hosted runner in bc-ctrl VPC
cd new-infra/environments/bc-prd/eu-central-1 && terraform init && terraform apply
```

Prerequisite: GitHub PAT in Secrets Manager:
```bash
aws secretsmanager create-secret --name bc/github/runnerpat \
  --secret-string "ghp_..." --region eu-central-1
```

To target a single environment via CI, use `workflow_dispatch` with `environment` input (`ctrl` | `prd` | `all`).

## Architecture

```
bc-ctrl (10.0.0.0/16)
  └── 1× t3.large EC2 runner (public subnet, public IP, IGW — no NAT)
        Labels: self-hosted,linux,bc-ctrl,bc-prd
        ↕ VPC Peering (free, same-region/account) ↕
bc-prd (10.30.0.0/16)
  └── EKS bc-prd-eks, K8s 1.35
        workload: 2× t3.large (private subnets, VPC endpoints)
        Cilium CNI + Tetragon + Falco

bc-xdr (10.11.0.0/16) — VPC + public subnet kept (SIEM i-04450a1e86a66a1b3 lives here)
                         TGW attachment removed; only VPC + public subnet in Terraform state

Transit Gateway — attachments destroyed by CI; pending manual destroy:
  cd new-infra/shared/transit-gateway && terraform destroy -auto-approve
```

Remote state wiring:
- bc-ctrl `terraform_config.tf`: `data "terraform_remote_state" "prd"` → reads bc-prd `vpc_id` for peering
- bc-prd `locals.tf`: `data "terraform_remote_state" "ctrl"` → reads bc-ctrl `peering_connection_id`

## Module structure

```
new-infra/
├── shared/
│   ├── transit-gateway/         # PENDING DESTROY — run after CI applies succeed
│   ├── github-runner/           # EMPTY STATE — runner now managed by bc-ctrl/vm.tf
│   └── ecr-pull-through-cache/  # ECR pull-through for Docker Hub, Quay, ghcr
├── environments/
│   ├── bc-xdr/eu-central-1/     # vpc.tf  locals.tf  global.tf  terraform_config.tf
│   │                              # (minimal: VPC + public subnet; SIEM blocks full destroy)
│   ├── bc-ctrl/eu-central-1/    # vpc.tf  vm.tf  runner_user_data.sh.tpl
│   │                              # locals.tf  terraform_config.tf  global.tf
│   └── bc-prd/eu-central-1/     # eks.tf  eks-addons.tf  helm-security.tf
│                                  # tracing-policies.tf  cilium.tf  cilium-policies.tf
│                                  # vpc.tf  locals.tf  terraform_config.tf
├── modules/
│   ├── eks-addons/              # Reusable: AWS LB Controller, external-secrets
│   └── network/
│       ├── vpc/                 # wraps terraform-aws-modules/vpc/aws v6.5.1
│       │   └── endpoints/       # VPC interface endpoints (S3, ECR, SSM, KMS, etc.)
│       └── transit-gateway/     # TGW module (kept for destroy reference only)
└── k8s/                         # Raw K8s manifests
```

Each environment's `locals.tf` is the single source of truth for CIDRs, node group sizing, EKS addon versions.

## CI workflows

- **PR → main**: `terraform-plan.yml` — runs `validate` + `plan` on ctrl + prd configs, posts plans as PR comments.
- **Push → main**: `terraform-deploy.yml`:
  1. `deploy-ctrl` (ubuntu-latest) → bc-ctrl: VPC + peering + runner VM
  2. `wait-for-runners` (240s) → depends on deploy-ctrl
  3. `deploy-prd` ([self-hosted, linux, bc-prd]) → EKS + Cilium bootstrap (depends on deploy-ctrl + wait-for-runners)

**CRD bootstrap pattern** (`deploy-prd` only): Two-step apply — Step 1 targets `helm_release.{cilium,tetragon,falco}` to install CRDs. Step 2 runs full plan + apply. No-op when `deploy_*_helm = false`.

Auth: GitHub OIDC → `arn:aws:iam::286439316079:role/GitHubActionsDeployRole`. No static secrets required. OIDC provider: `token.actions.githubusercontent.com`. Note: OIDC does NOT bypass SCP `p-bg731gel`.

Self-hosted runner prerequisite: GitHub PAT in Secrets Manager at `bc/github/runnerpat` (repo scope).

## EKS clusters

### bc-ctrl — NO EKS
Runner VM only: `bc-ctrl-runner` (t3.large, public subnet, SSM + public IP). Labels `self-hosted,linux,bc-ctrl,bc-prd` — handles both ctrl (AWS API) and prd (EKS API via VPC peering) CI jobs.

### bc-prd — EKS (K8s 1.35)
EKS cluster `bc-prd-eks` with `workload` node group.

Security stack:
- **Cilium CNI** (`cilium.tf`): aws-cni chaining mode. Gated by `local.deploy_cilium_helm`.
- **CiliumClusterwideNetworkPolicies** (`cilium-policies.tf`): default-deny + DNS egress + same-namespace.
- **Tetragon** (Layer 1 SIGKILL) + **Falco** (Layer 2 detection) in `helm-security.tf`, 6 TracingPolicies in `tracing-policies.tf`. Gated by `local.deploy_security_helm`.

| Group | Instance | Min/Desired/Max | Purpose |
|-------|----------|-----------------|---------|
| `workload` | t3.large | 2/2/3 | App pods + Cilium/Falco/Tetragon DaemonSets |

Private endpoint only. Images via ECR VPC endpoints (no internet egress from nodes).

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

Terraform infrastructure for **Big Chemistry's XDR v7 threat monitoring system** — three AWS VPCs connected via a shared Transit Gateway, with the XDR VPC acting as an inline security inspection chokepoint for all Production internet egress.

Region: `eu-central-1`. S3 state bucket: `bc-uatms-terraform-state`.

## Deployment order (strict)

Steps 1a and 1b run in parallel. Step 2 depends on 1a. Steps 3+4 depend on both 1b and 2.

```bash
# 1a. Transit Gateway (shared — must be first)
cd new-infra/shared/transit-gateway && terraform init && terraform apply

# 1b. GitHub Actions self-hosted runners (parallel with TGW)
#     Deploys EC2 runners in ctrl + prd VPCs for private K8s API access.
#     Prerequisite: store GitHub PAT in Secrets Manager:
#       aws secretsmanager create-secret --name bc/github/runnerpat \
#         --secret-string "ghp_..." --region eu-central-1
cd new-infra/shared/github-runner && terraform init && terraform apply

# 2. XDR VPC (creates the spoke-rt static default route — must precede ctrl/prd)
cd new-infra/environments/bc-xdr/eu-central-1 && terraform init && terraform apply

# 3. Control Plane VPC (parallel with prd — runs on self-hosted runner in VPC)
cd new-infra/environments/bc-ctrl/eu-central-1 && terraform init && terraform apply

# 4. Production VPC (parallel with ctrl — runs on self-hosted runner in VPC)
cd new-infra/environments/bc-prd/eu-central-1 && terraform init && terraform apply
```

To target a single environment via CI, use `workflow_dispatch` with the `environment` input (`tgw` | `xdr` | `ctrl` | `prd` | `runner` | `all`).

## Architecture

```
Transit Gateway (shared/transit-gateway)
├── shared-rt  ← bc-xdr + bc-ctrl attachments
└── spoke-rt   ← bc-prd (static 0.0.0.0/0 → XDR forces all prd egress through XDR for inspection)

bc-xdr (10.11.0.0/16)  — security tooling: Wazuh, Zeek, Suricata, MISP, Grafana, Keycloak
bc-ctrl (10.0.0.0/16)  — control plane
bc-prd (10.30.0.0/16)  — production spoke; internet egress routes through XDR
```

Remote state wiring: each environment reads TGW IDs from `data "terraform_remote_state" "tgw"` (S3 backend, key `shared/transit-gateway/terraform.tfstate`).

## Critical constraints

**TGW appliance_mode = `enable` on the XDR attachment.** Without this, TGW load-balances a 5-tuple flow across AZs, breaking symmetric routing on the Suricata/Zeek inline IPS pair. Never remove or change this.

**bc-xdr has NO EKS cluster.** `eks.tf` deploys only the inline inspection EC2 (`bc-xdr-test`, t3.medium, Zeek + Vector via Docker, SSM-only). EKS is not in scope for the XDR VPC. Security pipeline runs in bc-ctrl and bc-prd.

## Module structure

```
new-infra/
├── shared/
│   ├── transit-gateway/         # TGW + two route tables (shared-rt, spoke-rt)
│   ├── github-runner/           # Self-hosted GitHub Actions runners (EC2 in ctrl + prd VPCs)
│   └── ecr-pull-through-cache/  # ECR pull-through for Docker Hub, Quay, ghcr
├── environments/
│   ├── bc-xdr/eu-central-1/     # vpc.tf  eks.tf  locals.tf  global.tf  terraform_config.tf
│   ├── bc-ctrl/eu-central-1/    # eks.tf  eks-addons.tf  helm-security.tf  tracing-policies.tf  cilium.tf  cilium-policies.tf  flux.tf  route53.tf  wazuh-iam.tf  ...
│   └── bc-prd/eu-central-1/     # eks.tf  eks-addons.tf  helm-security.tf  tracing-policies.tf  cilium.tf  cilium-policies.tf  flux.tf  traffic-mirroring.tf  ...
├── modules/
│   ├── eks-addons/              # Reusable: AWS LB Controller, external-secrets, cert-manager, external-dns
│   └── network/
│       ├── vpc/                 # wraps terraform-aws-modules/vpc/aws v6.5.1
│       │   └── endpoints/       # VPC interface endpoints (S3, ECR, SSM, KMS, etc.)
│       └── transit-gateway/     # wraps the TGW resource
└── k8s/                         # Raw K8s manifests (reconciled by FluxCD, not manual kubectl)
    ├── wazuh/                   # Wazuh Manager + Indexer + Dashboard + Agent DaemonSet
    └── suricata/                # Suricata NIDS DaemonSet + configmap
```

Each environment's `locals.tf` is the single source of truth for CIDRs, node group sizing, EKS addon versions, and TGW remote state config.

## CI workflows

- **PR → main**: `terraform-plan.yml` — runs `validate` + `plan` on all five configs in parallel (tgw, runner, xdr, ctrl, prd), posts plans as PR comments.
- **Push → main**: `terraform-deploy.yml` — enforces: (tgw ∥ runner) → xdr → (ctrl ∥ prd). ctrl/prd run on self-hosted runners inside each VPC for private K8s API access. tgw/xdr/runner run on ubuntu-latest.

**CRD bootstrap pattern** (`deploy-ctrl` + `deploy-prd`): Two-step apply to solve the chicken-and-egg between Helm charts (which install CRDs) and `kubernetes_manifest` resources (which require those CRDs at plan time). Step 1 targets only `helm_release.{cilium,tetragon,falco}` to install CRDs. Step 2 runs the full plan + apply (CRDs now exist). No-op when `deploy_*_helm = false`.

Auth: GitHub OIDC → `arn:aws:iam::286439316079:role/GitHubActionsDeployRole`. No static secrets required. OIDC provider: `token.actions.githubusercontent.com`. Note: OIDC does NOT bypass SCP `p-bg731gel`.

Self-hosted runner prerequisite: GitHub PAT in Secrets Manager at `bc/github/runnerpat` (repo scope).

## EKS clusters

### bc-xdr — no EKS
EC2 inline inspection appliance only: `bc-xdr-test` (t3.medium, SSM-only, Zeek + Vector via Docker). No EKS. Security pipeline workloads run in bc-ctrl and bc-prd clusters.

### bc-ctrl — EKS (K8s 1.35, clusters UP)
Control plane. EKS cluster `bc-ctrl-eks` with `security` + `platform` node groups (node groups blocked by SCP `p-bg731gel`).

Security stack:
- **Cilium CNI** (`cilium.tf`): aws-cni chaining mode on top of vpc-cni. Adds eBPF network policy enforcement + Hubble L3-L7 observability. Gated by `local.deploy_cilium_helm`. operator on `platform` nodes.
- **CiliumClusterwideNetworkPolicies** (`cilium-policies.tf`): default-deny with 3 exceptions (kube-system unrestricted, DNS egress, same-namespace). Gated by same flag.
- **Tetragon** (Layer 1 SIGKILL) + **Falco** (Layer 2 detection) in `helm-security.tf`, 6 TracingPolicies in `tracing-policies.tf`. Gated by `local.deploy_security_helm` (default false for CI).

Addons: AWS LB Controller, external-secrets, cert-manager, external-dns via `eks-addons` module.

| Group | Instance | Min/Desired/Max | Purpose |
|-------|----------|-----------------|---------|
| `security` | m6a.xlarge | 2/2/6 | Wazuh Manager HA, Shuffle SOAR, DFIR-IRIS; taint `dedicated=security:NoSchedule` |
| `platform` | m6a.large | 2/2/6 | Enforcement API, Cilium Operator, Grafana, Kibana, Keycloak, Kyverno, Trivy + Sigstore |

Private endpoint only.

### bc-prd — EKS for workloads (K8s 1.35, clusters UP)
Production spoke. EKS cluster `bc-prd-eks` with `workload` node group (blocked by SCP `p-bg731gel`).

Security stack:
- **Cilium CNI** (`cilium.tf`): same aws-cni chaining as ctrl. operator on `workload` nodes (replicas=1 at desired_size=1). Images via ECR quay/ pull-through (no internet egress). Gated by `local.deploy_cilium_helm`.
- **CiliumClusterwideNetworkPolicies** (`cilium-policies.tf`): same 3 base policies as ctrl + Wazuh Agent egress to `10.11.0.0/16` TCP 1514/1515 (Wazuh Manager in bc-xdr via TGW).
- Traffic mirroring (VPC mirror → NLB → Suricata DaemonSet) in `traffic-mirroring.tf` + Lambda auto-mirror for ASG scaling.
- Same Tetragon + Falco + 6 TracingPolicies as ctrl.

| Group | Instance | Min/Desired/Max | Purpose |
|-------|----------|-----------------|---------|
| `workload` | m6a.large | 1/1/3 | App pods + Cilium/Falco/Tetragon/Wazuh Agent DaemonSets |

Private endpoint only. No internet egress — all traffic routes via TGW → XDR for inspection.

**Cilium image pre-seed required for bc-prd** before setting `deploy_cilium_helm = true`: pull from quay.io and push to ECR `286439316079.dkr.ecr.eu-central-1.amazonaws.com/quay/cilium/*` from a host with internet access (bc-ctrl bastion). See plan file for exact commands.

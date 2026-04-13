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

Steps 3 and 4 can run in parallel, but step 1 must always be first and step 2 must complete before 3/4.

```bash
# 1. Transit Gateway (shared — must be first)
cd new-infra/shared/transit-gateway && terraform init && terraform apply

# 2. XDR VPC (creates the spoke-rt static default route — must precede ctrl/prd)
cd new-infra/environments/bc-xdr/eu-central-1 && terraform init && terraform apply

# 3. Control Plane VPC (parallel with prd)
cd new-infra/environments/bc-ctrl/eu-central-1 && terraform init && terraform apply

# 4. Production VPC (parallel with ctrl)
cd new-infra/environments/bc-prd/eu-central-1 && terraform init && terraform apply
```

To target a single environment via CI, use `workflow_dispatch` with the `environment` input (`tgw` | `xdr` | `ctrl` | `prd` | `all`).

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

**SCP `p-bg731gel` (org `o-vkd12h7z3c`) blocks ALL `ec2:RunInstances on instance/*` account-wide.** This prevents ALL EKS node group creation across xdr, ctrl, and prd. The SCP is org-level — it cannot be fixed by Terraform config or by switching IAM principals (user vs role). Org admin must modify it before any EKS node groups can be created.

**bc-xdr has no EKS cluster.** `eks.tf` deploys only a t3.medium EC2 test instance (SSM-only) for TGW routing validation. EKS is not planned for XDR VPC.

```bash
# Connect to the XDR test instance
aws ssm start-session --target <xdr_test_instance_id output>
```

## Module structure

```
new-infra/
├── shared/transit-gateway/      # TGW + two route tables (shared-rt, spoke-rt)
├── environments/
│   ├── bc-xdr/eu-central-1/     # vpc.tf  eks.tf  locals.tf  global.tf  terraform_config.tf
│   ├── bc-ctrl/eu-central-1/    # same structure
│   └── bc-prd/eu-central-1/     # same structure
└── modules/network/
    ├── vpc/                     # wraps terraform-aws-modules/vpc/aws v6.5.1
    │   └── endpoints/           # VPC interface endpoints (S3, ECR, SSM, KMS, etc.)
    └── transit-gateway/         # wraps the TGW resource
```

Each environment's `locals.tf` is the single source of truth for CIDRs, node group sizing, EKS addon versions, and TGW remote state config.

## CI workflows

- **PR → main**: `terraform-plan.yml` — runs `validate` + `plan` on all four environments in parallel, posts plans as PR comments.
- **Push → main**: `terraform-deploy.yml` — enforces the deployment order above (tgw → xdr → ctrl ∥ prd).

Auth: GitHub OIDC → `arn:aws:iam::286439316079:role/GitHubActionsDeployRole`. No static secrets required. OIDC provider: `token.actions.githubusercontent.com`. Note: OIDC does NOT bypass SCP `p-bg731gel`.

## EKS clusters

### bc-xdr — no EKS
XDR VPC runs a single EC2 test instance (t3.medium, SSM only) for TGW/routing validation. No EKS. Security tooling (Wazuh, MISP, nProbe) is future scope, pending SCP resolution.

### bc-ctrl — EKS (pending SCP fix)
Control plane VPC runs an EC2 test instance (t3.large, SSM only) + EKS cluster with `security` + `platform` node groups. Node group creation blocked by SCP `p-bg731gel`.

| Group | Instance | Min/Desired/Max | Purpose |
|-------|----------|-----------------|---------|
| `security` | m6a.xlarge | 2/2/6 | Cilium/Falco/Tetragon DaemonSets; taint `dedicated=security:NoSchedule` |
| `platform` | m6a.large | 2/2/6 | Enforcement API (FastAPI + Celery + boto3/WAF/NFW workers), Cilium Operator, Grafana, Kibana, Keycloak, Kyverno (3 replicas), Trivy + Sigstore webhooks |

Private endpoint only.

### bc-prd — EKS for Cilium / Falco / Tetragon (pending SCP fix)

| Group | Instance | Min/Desired/Max | Purpose |
|-------|----------|-----------------|---------|
| `workload` | m6a.large | 1/1/3 | Cilium + Falco + Tetragon DaemonSets + app pods |

Private endpoint only. Helm chart deployment (`helm.tf`) is next step after SCP is resolved.

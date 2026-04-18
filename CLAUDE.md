# Claude Development Guidelines - XDR v8

## Project Overview
Architecture: 2-VPC hub-spoke via Peering (Brain: bc-ctrl, Data: bc-prd).

## MANDATORY: Agent & Skill Usage

**These rules are NON-NEGOTIABLE. You MUST follow them for every task.**

### Agent Dispatch Rules

Before doing ANY implementation work, dispatch the appropriate agent. Do NOT attempt domain-specific work inline.

| Task involves... | MUST dispatch | Escalate to |
|-----------------|---------------|-------------|
| Terraform files (`*.tf`) | `infrastructure-engineer` | `master-architect` |
| Security tools (Cilium, Falco, Tetragon, Wazuh, Suricata, Zeek, MISP) | `security-stack-engineer` | `master-architect` |
| GitHub Actions, CI/CD, runner | `pipeline-engineer` | `master-architect` |
| Adding/changing AWS resources | `cost-optimizer` (review) + domain agent (implement) | `master-architect` |
| IAM, SGs, network segmentation, access control | `zero-trust-architect` (review) + domain agent (implement) | `master-architect` |
| Cross-domain problems, architecture decisions, agent stuck 2+ times | `master-architect` directly | User |

**Escalation rule**: If an agent fails on the same problem twice with no progress, escalate to `master-architect`. Do NOT retry the same approach a third time.

### Skill Invocation Rules

You MUST invoke the matching skill BEFORE taking action in these scenarios:

| Scenario | MUST invoke | Before... |
|----------|------------|-----------|
| Any Terraform change (write, edit, propose) | `/tf-review` | Committing or applying |
| Any K8s manifest change (write, edit, propose) | `/k8s-review` | Applying to cluster |
| Adding any AWS resource | `/cost-check` | Writing the Terraform |
| Before `terraform apply` (manual or pipeline) | `/deploy-check` | Running apply |
| Periodic or pre-release | `/security-audit` | Any deployment |
| Security event investigation | `/incident-response` | Ad-hoc investigation |

### Multi-Agent Workflows

For complex tasks, use this pattern:

1. **Plan**: Dispatch `master-architect` for strategy and task decomposition
2. **Review**: Dispatch `cost-optimizer` + `zero-trust-architect` in parallel for cost/security review of the plan
3. **Implement**: Dispatch domain agent (`infrastructure-engineer`, `security-stack-engineer`, or `pipeline-engineer`)
4. **Validate**: Invoke relevant skill (`/tf-review`, `/k8s-review`, `/deploy-check`)

For simple, single-domain tasks, skip step 1 — dispatch domain agent directly, then validate with skill.

---

## Resource Map
- **Terraform Configs**: `new-infra/environments/{env}/eu-central-1/`
- **Networking Logic**: `new-infra/environments/bc-prd/eu-central-1/vpc.tf` (Peering + local fck-nat).
- **Security Logic**: `new-infra/environments/bc-prd/eu-central-1/helm-security.tf` (Mandatory Stack).
- **Runner Setup**: `new-infra/environments/bc-ctrl/eu-central-1/vm.tf` (GitHub Runner bootstrap).
- **K8s Manifests**: `new-infra/k8s/{wazuh,suricata,zeek,misp}/`

## Critical AI Guardrails
- **Mandatory Stack**: bc-prd EKS MUST run Cilium, Falco, and Tetragon. bc-ctrl has no EKS cluster.
- **No Transitive Routing**: VPC Peering DOES NOT support internet egress through a peer. `bc-prd` MUST have its own `fck-nat` for worker node internet access.
- **EKS Access Management**: NEVER use `enable_cluster_creator_admin_permissions`. It causes 409 conflicts between local and CI/CD runs. ALWAYS use explicit `access_entries`.
- **Node Capacity**: bc-prd workers = `t3.medium` (t3.small fails, pod limit 11). bc-ctrl has NO EKS cluster — all workloads on bare EC2.
- **Runner Support**: The self-hosted runner needs `nodejs`, `git`, `jq`, `libicu`, `terraform`, and `kubectl`.
- **Cost ceiling**: ~$565/month baseline. Any change adding >$10/month needs explicit justification.

## Common Failure Modes
- **409 Conflict on Access Entry**: Caused by `enable_cluster_creator_admin_permissions = true`. Switch to explicit entries.
- **Helm Timeout (i/o timeout)**: Nodes lack internet egress. Check `fck-nat` iptables and MASQUERADE rules.
- **Worker Node Not Joining**: Check VPC Endpoints (STS, EKS, EC2) in the private VPC.
- **CRD Not Found**: K8s manifests applied before Helm CRD bootstrap. Use `-target` for Cilium/Falco/Tetragon first.

## Build & Deploy
- **Step 1 (Ctrl)**: `cd new-infra/environments/bc-ctrl/eu-central-1 && terraform apply`
- **Step 2 (Prd)**: `cd new-infra/environments/bc-prd/eu-central-1 && terraform apply`

## Security Stack Verification
- **Falco**: `kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco`
- **Cilium**: `kubectl -n kube-system exec ds/cilium -- cilium status`
- **Tetragon**: `kubectl -n kube-system logs ds/tetragon -c export-stdout`

## Known Issues & Troubleshooting

### Shuffle (EKS)
- **Deployment Timeout**: Shuffle (OpenSearch + Backend) takes >10 minutes to initialize. Use `timeout = 900` and `wait = true` in `helm_release`.
- **Persistent Volumes**: Requires `aws-ebs-csi-driver` EKS addon and `AmazonEBSCSIDriverPolicy` on node roles.
- **StorageClass**: Ensure a default StorageClass (e.g., `gp2`) is present. Patch with: `kubectl patch storageclass gp2 -p '{"metadata": {"annotations":{"storageclass.kubernetes.io/is-default-class":"true"}}}'`.
- **Pending Pods**: If OpenSearch pods are Pending, check `kubectl get pvc -n shuffle`. Unbound PVCs usually mean missing CSI driver or default StorageClass.

### Wazuh (EC2)
- **Dashboard "No Indices"**: Usually means `filebeat` is not running on the Wazuh manager. `filebeat` is responsible for shipping alerts to the indexer.
- **API Offline/Unauthorized**: The initial setup script must handle the transition from factory default password (`wazuh-wui`) to the custom Secrets Manager password. Readiness probes should check both if sync fails.
- **Re-provisioning**: If `phase3-install-wazuh.sh` is updated, the EC2 instance must be tainted and re-applied: `terraform taint aws_instance.wazuh`.

## Configuration & Policies
- **Network Policies**: Use `CiliumNetworkPolicy` CRDs.
- **Enforcement**: Use `TracingPolicy` CRDs for Tetragon SIGKILL rules.
- **Runtime Rules**: Update `falco_rules.local.yaml` via Helm values.

## Agents (in `.claude/agents/`)

| Agent | Model | Domain |
|-------|-------|--------|
| `master-architect` | Opus | Deep reasoning, cross-domain strategy, unsticking agents, architecture decisions |
| `infrastructure-engineer` | Sonnet | Terraform, VPC, EKS, fck-nat, peering, endpoints |
| `security-stack-engineer` | Sonnet | Cilium, Falco, Tetragon, Wazuh, Suricata, Zeek, MISP |
| `pipeline-engineer` | Sonnet | GitHub Actions CI/CD, self-hosted runner |
| `cost-optimizer` | Sonnet | AWS cost analysis, right-sizing, resource waste |
| `zero-trust-architect` | Sonnet | Network segmentation, least privilege, posture review |

## Skills (in `.claude/skills/`)

| Skill | Trigger | Purpose |
|-------|---------|---------|
| `/tf-review` | Before TF changes | Validate against project guardrails + cost + security |
| `/security-audit` | Periodic / pre-deploy | Audit full XDR stack for gaps and misconfigs |
| `/cost-check` | Before adding resources | Monthly cost impact analysis against $565 baseline |
| `/deploy-check` | Before terraform apply | Pre-deployment validation checklist |
| `/k8s-review` | Before K8s manifest changes | Security compliance + resource limits + XDR compat |
| `/incident-response` | During security events | Guided investigation using Falco/Tetragon/Wazuh/Suricata/Zeek |

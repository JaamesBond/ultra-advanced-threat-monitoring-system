# Claude Development Guidelines - XDR v8

## Project Overview

**UATMS** (Ultra Advanced Threat Monitoring System) — a full XDR platform for Big Chemistry built on AWS `eu-central-1`, account `286439316079`.

Architecture: 2-VPC hub-spoke via VPC Peering. No Transit Gateway.
- **bc-ctrl** (The Brain): `10.0.0.0/16` — Control plane, EC2-only. Wazuh all-in-one, MISP, GitHub Runner.
- **bc-prd** (The Data): `10.30.0.0/16` — Production EKS cluster. Security stack + sensor DaemonSets.

Goal: operational Cilium + Falco + Tetragon + Hubble on bc-prd EKS, with Wazuh manager on bc-ctrl EC2 ingesting alerts from Suricata, Zeek, Falco, and Tetragon on bc-prd nodes.

---

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

## Architecture

### Network Topology

| VPC | CIDR | Purpose |
|-----|------|---------|
| bc-ctrl | `10.0.0.0/16` | Control plane — EC2 workloads only, no EKS |
| bc-prd | `10.30.0.0/16` | Production — EKS cluster, security stack |

**Peering**: bc-prd (requester) → bc-ctrl (accepter). Managed entirely from bc-prd Terraform to avoid cross-stack reads on empty state.

**Private DNS**: `bc-ctrl.internal` Route53 private zone — associated with BOTH VPCs so bc-prd agents resolve Wazuh/MISP by name.

**fck-nat**: Both VPCs have a `t4g.nano` ARM64 fck-nat instance (AMI `ami-077be74ead50d19aa`) for internet egress. bc-prd's fck-nat handles only bc-prd nodes; bc-ctrl's handles bc-ctrl EC2s.

**VPC Endpoints (bc-prd)**: S3, EC2, ECR API, ECR DKR, STS, SSM, CloudWatch Logs, KMS.

### bc-ctrl EC2 Inventory

| Instance | Type | Subnet | OS | DNS (bc-ctrl.internal) | Purpose |
|----------|------|--------|----|------------------------|---------|
| `wazuh-ctrl` | t3.xlarge | private[0] | Amazon Linux 2023 | `wazuh-manager.bc-ctrl.internal`, `wazuh-indexer.bc-ctrl.internal`, `wazuh-dashboard.bc-ctrl.internal` | Wazuh all-in-one (Manager + OpenSearch Indexer + Dashboard). 60 GiB root + 200 GiB gp3 data EBS |
| `misp-ctrl` | t3.large | private[0] | Amazon Linux 2023 | `misp.bc-ctrl.internal` | MISP threat intel platform + co-located MySQL. 30 GiB root + 60 GiB gp3 data EBS |
| `shuffle-ec2` | t3.large | private[0] | Ubuntu 24.04 | — | Shuffle SOAR v2.2.0 via Docker Compose. No IAM instance profile registered yet. |
| `github-runner-ctrl` | t3.small | public[0] | Amazon Linux 2023 | — | Self-hosted GitHub Actions runner. Used by `production-plane` CI job |

Wazuh and MISP install via scripts fetched from S3 at boot (`bc-uatms-wazuh-snapshots` bucket). To re-provision, taint and re-apply: `terraform taint aws_instance.wazuh` or `aws_instance.misp`.

**Shuffle** is deployed as Docker Compose on Ubuntu 24.04 — NOT on EKS. Requires `vm.max_map_count=262144` (set via sysctl in user_data). Runs Shuffle v2.2.0.

### bc-prd EKS

- **Cluster**: `bc-uatms-prd-eks`, Kubernetes 1.35, private endpoint + public (kept public until Helm complete)
- **Nodes**: 2× `t3.medium` (min/max/desired = 2). DO NOT use t3.small (pod limit too low).
- **CNI**: Cilium in ENI mode (`ipam.mode=eni`, `routingMode=native`). aws-node intentionally disabled via `nodeSelector: non-existent=true`.
- **EBS CSI**: Currently disabled (commented out) — required only if Shuffle is re-enabled.

### Security Stack (bc-prd Helm Releases)

| Component | Chart | Version | Namespace |
|-----------|-------|---------|-----------|
| Cilium | cilium/cilium | 1.19.3 | kube-system |
| Falco | falcosecurity/falco | 8.0.2 | falco |
| Tetragon | cilium/tetragon | 1.6.1 | kube-system |
| External Secrets | charts.external-secrets.io | 0.10.7 | external-secrets |

Cilium has Hubble relay + UI enabled (`policyEnforcementMode=default`). Falco uses `modern_ebpf` driver.

### bc-prd DaemonSets (K8s Manifests)

| DaemonSet | Namespace | Image | Purpose |
|-----------|-----------|-------|---------|
| `wazuh-agent` | wazuh | `286439316079.dkr.ecr.eu-central-1.amazonaws.com/wazuh-agent:4.9.0` | Ships Suricata/Zeek/Falco/syslog to Wazuh manager |
| `zeek` | zeek | `zeek/zeek:7.0.5` | Network NSM. Sidecar: `misp-intel-sync` (Alpine, pulls MISP IOCs → Zeek Intel format every 1h) |
| `suricata` | suricata | `jasonish/suricata:7.0.7` | IDS/IPS. Sidecars: `misp-rule-sync` (Alpine, MISP → Suricata rules every 1h) + `rule-refresher` (ET Open rules every 6h) |

**CRITICAL**: Zeek and Suricata DaemonSets require `nodeSelector: role: workload`. If this node label is missing from the node group, pods will never schedule — 0 replicas is NOT an error in the DaemonSet itself.

**Shuffle SOAR**: Moved off EKS entirely. Now runs as Docker Compose on `shuffle-ec2` (t3.large, Ubuntu 24.04) in bc-ctrl private subnet. The EKS Helm release remains commented out.

### Data Flow (Telemetry Pipeline)

```
bc-prd nodes:
  Suricata → eve.json → /var/log/suricata/ (hostPath)
  Zeek     → conn/dns/http/notice.log → /var/log/zeek/ (hostPath)
  Falco    → falco.json → /var/log/falco/ (hostPath)
  ↓
  wazuh-agent DaemonSet (reads all hostPath logs)
  ↓ TCP 1514/1515 via VPC peering
  bc-ctrl: wazuh-manager EC2 → OpenSearch indexer → Dashboard

MISP IOC sync (every 1h):
  zeek:misp-intel-sync sidecar → MISP API → indicators.intel (Zeek Intel format)
  suricata:misp-rule-sync sidecar → MISP API → misp.rules (Suricata rule format, SIDs 9000000+)
```

### External Secrets → AWS Secrets Manager

External Secrets Operator uses IRSA (`bc-uatms-prd-external-secrets` role) to sync:

| K8s Secret | Namespace | SM Path |
|-----------|-----------|---------|
| `suricata-misp-secret` | suricata | `bc/suricata/misp` |
| `zeek-misp-secret` | zeek | `bc/zeek/misp` (implied) |
| Wazuh creds | external-secrets | `bc/wazuh/manager` |

External Secrets Operator must be running BEFORE applying Suricata/Zeek manifests that reference these secrets. If `webhook.failurePolicy=Ignore` is not set, a crashed webhook blocks all K8s resource creation.

---

### Victim Machine (Testing Infrastructure)

A set of scripts exists to stand up simulated victim EC2s for detection testing. These are separate from production infra — they are Ubuntu 24.04 hosts you provision manually for red-team/detection exercises:

| Script | Purpose |
|--------|---------|
| `new-infra/scripts/victim-install-wazuh-agent.sh` | Installs Wazuh agent 4.9.2 on Ubuntu 24.04, registers to manager at `10.0.10.208:1514`, full ossec.conf |
| `new-infra/scripts/victim-install-suricata.sh` | Installs Suricata on Ubuntu 24.04 |
| `new-infra/scripts/victim-install-zeek.sh` | Installs Zeek on Ubuntu 24.04 |
| `new-infra/scripts/victim-configure-detection.sh` | Configures Suricata with brute-force, Nmap/portscan, and DDoS detection rules (custom SIDs 9000001+) |

**Note**: Victim scripts use Wazuh agent **4.9.2** (Ubuntu package available) while the EC2 manager uses **4.14.4** — the manager is backwards-compatible with older agents.

### Sigma Rules

Detection rules in SIGMA format at `new-infra/k8s/sigma/rules/`. Two rules currently:
- `aws-cloudtrail/aws-console-login-no-mfa.yml` — Console login without MFA
- `kubernetes/k8s-privileged-pod.yml` — Privileged pod creation (container escape vector)

These are not yet wired to any SIEM pipeline — they document intended detections.

---

## Resource Map

- **Terraform Configs**: `new-infra/environments/{env}/eu-central-1/`
- **bc-ctrl VPC/fck-nat/peering**: `new-infra/environments/bc-ctrl/eu-central-1/vpc.tf`
- **bc-ctrl GitHub Runner + MISP**: `new-infra/environments/bc-ctrl/eu-central-1/vm.tf`
- **bc-ctrl Shuffle EC2**: `new-infra/environments/bc-ctrl/eu-central-1/shuffle.tf`
- **bc-ctrl Wazuh EC2**: `new-infra/environments/bc-ctrl/eu-central-1/wazuh-ec2.tf`
- **bc-ctrl DNS (Route53)**: `new-infra/environments/bc-ctrl/eu-central-1/route53.tf`
- **bc-prd VPC/fck-nat/peering/endpoints**: `new-infra/environments/bc-prd/eu-central-1/vpc.tf`
- **bc-prd EKS**: `new-infra/environments/bc-prd/eu-central-1/eks.tf`
- **bc-prd Security Stack (Helm)**: `new-infra/environments/bc-prd/eu-central-1/helm-security.tf`
- **K8s Manifests**: `new-infra/k8s/{wazuh-agent,suricata,zeek,tetragon}/`
- **Sigma Rules**: `new-infra/k8s/sigma/rules/{aws-cloudtrail,kubernetes}/`
- **Wazuh Install Script**: `new-infra/scripts/phase3-install-wazuh.sh`
- **MISP Install Script**: `new-infra/scripts/phase4-install-misp.sh`
- **Victim Machine Scripts**: `new-infra/scripts/victim-install-{wazuh-agent,suricata,zeek}.sh`, `victim-configure-detection.sh`
- **Shuffle EC2**: `new-infra/environments/bc-ctrl/eu-central-1/shuffle.tf` (Docker Compose on Ubuntu 24.04, bc-ctrl private subnet)
- **Modules**: `new-infra/modules/network/vpc/`, `vpc_peering/`, `vpc/endpoints/`, `eks-addons/`
- **Rollout Plan**: `SECURITY_STACK_ROLLOUT_PLAN.md` (phase tracker — read before touching stack)

---

## Critical AI Guardrails

- **Mandatory Stack**: bc-prd EKS MUST run Cilium (ENI mode), Falco, and Tetragon. bc-ctrl has NO EKS cluster — all bc-ctrl workloads are bare EC2.
- **No Transitive Routing**: VPC Peering does NOT forward internet traffic. bc-prd MUST have its own `fck-nat`; bc-prd nodes cannot reach the internet via bc-ctrl's fck-nat.
- **EKS Access Management**: NEVER use `enable_cluster_creator_admin_permissions`. It causes 409 conflicts between local and CI runs. ALWAYS use explicit `access_entries`.
- **Node Capacity**: bc-prd workers = `t3.medium`. t3.small fails (pod limit too low at 11).
- **Wazuh Version Pinning**: Pin to `4.14.4` across all three components (indexer/manager/dashboard). The `4.9.x` repo (`packages.wazuh.com/4.9/`) returned HTTP 403 — that repo is retired. Use `4.x` rolling repo which serves 4.14.4.
- **Cilium ENI mode is the established pattern**: Do NOT switch to chaining mode. ENI mode + aws-node disabled is working and stable.
- **CRD bootstrap order**: Apply Cilium/Falco/Tetragon Helm releases BEFORE Zeek/Suricata/wazuh-agent K8s manifests. CiliumNetworkPolicy CRDs must exist before manifests that use them.
- **External Secrets webhook**: Must be running before manifests with ExternalSecret resources. Set `webhook.failurePolicy=Ignore` to prevent blocking if it's not yet ready.
- **Cost ceiling**: ~$565/month baseline. Any change adding >$10/month needs explicit justification.
- **KMS drift prevention**: `kms_key_administrators` is pinned to `GitHubActionsDeployRole` ARN. Without this, local vs CI applies flip-flop the KMS key policy on every plan.

---

## Build & Deploy

### CI Pipeline (Primary — triggers on push to `main` under `new-infra/**`)

Two-job sequential pipeline (`terraform-deploy.yml`):

**Job 1: `ctrl-plane`** (runs on `ubuntu-latest`)
- Stage 1: targeted apply — VPC, fck-nat, Route53, GitHub Runner
- Stage 2: full `terraform apply` (reconcile all bc-ctrl resources)
- Waits for Wazuh + MISP EC2 instances to be SSM-reachable before handing off

**Job 2: `production-plane`** (runs on `self-hosted` runner in bc-ctrl, needs Job 1)
- Stage 1: targeted apply — VPC, endpoints, fck-nat, peering, EKS
- Stage 2: targeted apply — Cilium, Falco, Tetragon, External Secrets (CRD bootstrap)
- Waits for CRDs to propagate + external-secrets webhook ready
- Applies K8s manifests: Zeek → Suricata → wazuh-agent (via `kubectl kustomize | sed | kubectl apply`)

The staged apply exists because applying Helm releases on a freshly created EKS cluster fails if EKS isn't ready yet — splitting into two targeted passes solves the cold-start race.

### Manual Apply (local)

```bash
# Step 1 — bc-ctrl (all EC2 infra)
cd new-infra/environments/bc-ctrl/eu-central-1
terraform init && terraform apply

# Step 2 — bc-prd (EKS + security stack)
cd new-infra/environments/bc-prd/eu-central-1
terraform init && terraform apply
```

### Manual K8s Manifest Apply

```bash
# Export kubeconfig for bc-prd
aws eks update-kubeconfig --region eu-central-1 --name bc-uatms-prd-eks --kubeconfig /tmp/kubeconfig-prd
export KUBECONFIG=/tmp/kubeconfig-prd

# Apply manifests (substituting account ID)
kubectl kustomize new-infra/k8s/zeek | sed "s/\${AWS_ACCOUNT_ID}/286439316079/g" | kubectl apply -f -
kubectl kustomize new-infra/k8s/suricata | sed "s/\${AWS_ACCOUNT_ID}/286439316079/g" | kubectl apply -f -
kubectl kustomize new-infra/k8s/wazuh-agent | sed "s/\${AWS_ACCOUNT_ID}/286439316079/g" | kubectl apply -f -
```

---

## Security Stack Verification

All kubectl commands target bc-prd EKS. bc-ctrl has no EKS cluster.

```bash
# Cilium
kubectl -n kube-system exec ds/cilium -- cilium status --brief

# Hubble UI (port-forward — no ingress yet)
kubectl -n kube-system port-forward svc/hubble-ui 12000:80

# Falco
kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco --tail=20

# Tetragon
kubectl -n kube-system logs ds/tetragon -c export-stdout --tail=20

# Wazuh Manager (EC2 via SSM)
aws ssm start-session --target <wazuh-instance-id> --region eu-central-1
# On instance: cat /var/log/wazuh-install.log | tail -50
#              systemctl status wazuh-manager wazuh-indexer wazuh-dashboard filebeat

# MISP (EC2 via SSM)
aws ssm start-session --target <misp-instance-id> --region eu-central-1
# On instance: cat /var/log/misp-install.log | tail -50

# Suricata (must have role=workload node label)
kubectl -n suricata get pods -o wide
kubectl -n suricata logs ds/suricata -c suricata --tail=20

# Zeek
kubectl -n zeek get pods -o wide
kubectl -n zeek logs ds/zeek -c zeek --tail=20

# External Secrets
kubectl -n external-secrets get pods
kubectl -n suricata get externalsecret,secret
```

---

## Common Failure Modes

- **409 Conflict on Access Entry**: Caused by `enable_cluster_creator_admin_permissions = true`. Switch to explicit entries.
- **Helm Timeout (i/o timeout)**: Nodes lack internet egress. Check `fck-nat` iptables and MASQUERADE rules (`iptables -t nat -L POSTROUTING -n -v`).
- **Worker Node Not Joining**: Check VPC Endpoints (STS, EKS, EC2) in the private VPC.
- **CRD Not Found**: K8s manifests applied before Helm CRD bootstrap. Use `-target` for Cilium/Falco/Tetragon first, wait for CRDs, then apply manifests.
- **Suricata/Zeek: 0 pods, never scheduled**: Missing `role=workload` node label on EKS worker nodes. Label them: `kubectl label node <node> role=workload`.
- **Wazuh agent stuck Init:0/1**: Pre-existing bug (out of scope per directive). Do not spend time on it unless user explicitly asks.
- **External Secrets webhook blocks resource creation**: Set `webhook.failurePolicy=Ignore` and use `continue-on-error: true` when waiting for the rollout.
- **Wazuh Dashboard "No Indices"**: `filebeat` not running on the manager EC2. SSH in via SSM and run `systemctl start filebeat`.
- **Wazuh re-provisioning**: If `phase3-install-wazuh.sh` changes, taint the instance: `terraform taint aws_instance.wazuh` then re-apply. The script hash is embedded in user_data as a comment to force replacement detection.
- **KMS key policy flip-flop**: If plan shows KMS key policy changes on every run, ensure `kms_key_administrators` is pinned to the CI role ARN, not the identity running the plan.

---

## Known Issues & Troubleshooting

### Wazuh (EC2)
- **Dashboard "No Indices"**: `filebeat` not running. Start it via SSM session.
- **API Offline/Unauthorized**: Setup script transitions from factory password (`wazuh-wui`) to Secrets Manager password. Check `/var/log/wazuh-install.log` for where it stopped.
- **Re-provisioning**: Taint instance (`terraform taint aws_instance.wazuh`) if `phase3-install-wazuh.sh` is modified.
- **Version**: Must use `4.14.4` — `4.9.x` repo is retired (HTTP 403). All three components (indexer/manager/dashboard) must be on the same version.

### MISP (EC2)
- **Install log**: `/var/log/misp-install.log`
- **API key**: Stored in `bc/misp*` Secrets Manager paths. Zeek and Suricata sidecars pull this via External Secrets.
- **Self-signed cert**: MISP uses a self-signed cert. Sidecars use `curl -k` — this is a known gap (tracked in deferred list).

### Shuffle (EC2 — bc-ctrl)
- **Moved off EKS** — now `shuffle-ec2` (t3.large, Ubuntu 24.04, private subnet) in bc-ctrl, running Shuffle v2.2.0 via Docker Compose.
- Requires `vm.max_map_count=262144` for OpenSearch (set in user_data via sysctl).
- No SSM instance profile registered yet — access only via VPC-internal routing.
- EKS Helm release remains commented out in `helm-security.tf`.

### Cilium ENI Mode
- aws-node DaemonSet is kept running but neutered via `nodeSelector: non-existent=true` on the original aws-node pods — Cilium takes over IP management completely.
- Do NOT switch to chaining mode. ENI mode is stable.

---

## Current Rollout Status (see `SECURITY_STACK_ROLLOUT_PLAN.md` for details)

| Phase | Status | Summary |
|-------|--------|---------|
| Phase A | Done | Suricata memory tuning (requests 2Gi → 512Mi) |
| Phase B | In progress | Hubble UI enabled — B.7-B.12 pending CI apply to validate |
| Phase C | Superseded | bc-ctrl EKS removed; Wazuh/MISP migrated to EC2 |
| Phase D | In progress | CiliumNetworkPolicy manifests for wazuh-agent/suricata/zeek |
| Phase E | Superseded | Pipeline already rewritten with proper structure |
| Phase F | Not started | eks-security-stack module to make stack mandatory |

---

## Configuration & Policies

- **Network Policies**: Use `CiliumNetworkPolicy` CRDs (in `new-infra/k8s/<tool>/cilium-netpol.yaml`)
- **Enforcement**: Use `TracingPolicy` CRDs for Tetragon SIGKILL rules (`new-infra/k8s/tetragon/tracing-policy.yaml`)
- **Runtime Rules**: Update `falco_rules.local.yaml` via Helm values (`new-infra/environments/bc-prd/eu-central-1/falco-rules.yaml`)
- **Falco driver**: `modern_ebpf` (not legacy eBPF or kernel module)
- **Tetragon SIGKILL policy**: blocks execution of `nc`, `nmap` on cluster nodes

## AWS Resources

| Resource | ID/Name |
|----------|---------|
| AWS Account | `286439316079` |
| Region | `eu-central-1` |
| TF State Bucket | `bc-uatms-terraform-state` |
| Wazuh Snapshots + Scripts | `bc-uatms-wazuh-snapshots` |
| VPC Flow Logs | `bc-vpcflow-logs` |
| CloudTrail Logs | `bc-cloudtrail-logs` |
| GuardDuty Logs | `bc-guardduty-logs` |
| Config Logs | `bc-config-logs` |
| CI Role | `arn:aws:iam::286439316079:role/GitHubActionsDeployRole` |
| KMS pin (EKS) | Same CI role ARN in `kms_key_administrators` |

## Secrets Manager Layout

| Path | Contents | Used by |
|------|----------|---------|
| `bc/wazuh/manager` | `INDEXER_PASSWORD`, `API_PASSWORD`, `API_USERNAME`, `INDEXER_USERNAME`, etc. | Wazuh install script, External Secrets |
| `bc/misp*` | MISP admin credentials | MISP install script, Wazuh EC2 |
| `bc/suricata/misp` | `MISP_API_KEY` | External Secrets → suricata-misp-secret |
| `bc/github/runnerpat` | GitHub PAT | Runner registration (user_data) |

---

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

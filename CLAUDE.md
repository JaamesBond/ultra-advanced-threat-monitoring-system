# Claude Development Guidelines - XDR v8

## Project Overview

**UATMS** (Ultra Advanced Threat Monitoring System) — a full XDR platform for Big Chemistry built on AWS `eu-central-1`, account `845517756853`.

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
| `wazuh-agent` | wazuh | `845517756853.dkr.ecr.eu-central-1.amazonaws.com/wazuh-agent:4.14.4` | Ships Suricata/Zeek/Falco/syslog to Wazuh manager |
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
- **`bootstrap_self_managed_addons = false`**: Always pin this in `eks.tf`. EKS module v20.37+ defaults it to `true`, which would force-replace the existing cluster (destroy + create) because the cluster was created with `false` (Cilium handles CNI/kube-proxy).
- **CNP `toEntities: kube-apiserver` does NOT match the API server when Cilium `kubeProxyReplacement=true`**: Cilium's BPF LB rewrites `172.20.0.1:443` to the API server backend ENI IPs *before* policy evaluation. Those ENIs have `remote-node` identity, not `reserved:kube-apiserver`. Every system CNP that allows API egress MUST list both: `toEntities: [kube-apiserver, cluster]`. See `system-netpols/external-secrets-netpol.yaml` for the canonical pattern. Discovered 2026-05-09 — see `SESSION_2026-05-09_NOMAD_DEPLOY.md`.
- **KMS-encrypted Secrets Manager secrets need `kms:Decrypt` for the consumer**: An IRSA role with `secretsmanager:GetSecretValue` on a secret ARN is INSUFFICIENT if the secret is encrypted with a non-default KMS key. ESO's ClusterSecretStore validates as `Ready=True` (no KMS needed for that path) but every `ExternalSecret` then fails with `AccessDeniedException: Access to KMS is not allowed` until the role gains `kms:Decrypt` + `kms:DescribeKey` on the encrypting key. Always scope with `kms:ViaService = secretsmanager.<region>.amazonaws.com` so the grant can't be misused for raw KMS ops. Pattern in `helm-security.tf` for the ESO role.
- **Pipeline `-target=` lists must enumerate every TF resource for bc-prd**: `terraform apply -target=X` silently skips any resource not in the target list. New `kubernetes_*`, `aws_iam_role*`, and `helm_release` resources MUST be added to the right Stage's target list in `.github/workflows/terraform-deploy.yml`. Audit rule comment is at the top of "Terraform Apply (Prd) — Stage 1".
- **Pod limit on `t3.medium` workload nodes is 17 (VPC CNI)**: After deploying NOMAD Oasis the workload pool became "Too many pods" full and any new Deployment without a toleration for `dedicated=nomad:NoSchedule` could not schedule anywhere. Helm releases for kube-system controllers (ESO, ALB controller, etc.) MUST carry the toleration so they can spill onto the nomad node when workload is full.
- **vpc-cni addon MUST have `before_compute = true`**: Without it, EKS creates node groups before the CNI addon is installed. Nodes launch without any CNI → stay `NotReady` → EKS marks node group `CREATE_FAILED: NodeCreationFailure`. This only manifests on a fresh cluster (cold-start); an existing cluster survives because nodes are already Ready. Fix: `before_compute = true` in the `vpc-cni` block inside `cluster_addons` in `eks.tf`. Discovered 2026-05-10 — run 25624059541 Stage 1 failure.
- **kube-proxy MUST stay in `cluster_addons` for cold-start bootstrap**: Removing kube-proxy (Phase G) works on a running cluster because Cilium kubeProxyReplacement=true is already managing ClusterIP routing. On a **fresh cluster**, Cilium is not installed until Stage 2. Without kube-proxy, 172.20.0.1 (kubernetes ClusterIP) is unreachable → coredns `kubernetes` plugin fails → all pod DNS breaks → ebs-csi can't resolve STS → IRSA fails → addons stay in `CREATING` and time out after 20 min. Fix: keep `kube-proxy = { most_recent = true }` in `cluster_addons`. Once Cilium installs with `kubeProxyReplacement=true`, its BPF hooks intercept traffic before iptables, making kube-proxy's rules redundant but harmless. Discovered 2026-05-10 — run 25627024043.
- **Cilium `policyEnforcementMode=default`, NOT `always`**: `always` triggers an endpoint-registration race — pods starting under load (cold-start, scale-up, taint-driven new node) get identity `reserved:unmanaged` (id=3) and are implicitly default-denied before their CNP is installed, causing ebs-csi-node CrashLoopBackOff, ESO STS timeouts, etc. With `default`, unregistered endpoints are not denied; explicit per-endpoint enforcement comes from CNPs in `new-infra/k8s/system-netpols/` and per-app `cilium-netpol.yaml`. All workload namespaces (wazuh, suricata, zeek, falco, external-secrets, kube-system, nomad-oasis) have at least one CNP — audit confirmed 2026-05-10. Discovered 2026-05-10.
- **Switching `policyEnforcementMode` mid-flight does NOT auto-heal already-stuck pods**: Cilium re-evaluates policy mode for *new* endpoint registrations only. Pods that registered as `reserved:unmanaged` under the old mode keep that identity until their pod is **deleted and recreated**. Container restarts (from CrashLoop) do NOT count — same pod = same Cilium endpoint. After flipping `always` → `default` on 2026-05-10, the recovery procedure was: `kubectl delete pod` for every pod still showing `reserved:unmanaged` or stuck `CreateContainerConfigError`/CrashLoopBackOff. On bc-prd this was: ESO controller, ESO cert-controller, both ebs-csi-node pods on overloaded nodes, all 5 Temporal services + Temporal-schema Job, and NOMAD app/worker/proxy. After deletion the pods came back clean and ExternalSecrets synced within ~60s, PVCs bound, Temporal connected to Postgres. **For a fresh cold-start under `policyEnforcementMode=default`, this manual step is NOT required** — the fix prevents recurrence. The recovery is only needed for clusters that ran under `always` and were flipped without rebuild.
- **CNP selectors MUST match the actual labels Helm sub-charts emit, not what the parent chart's recommended labels would be**: Mixed sub-charts in NOMAD Oasis use inconsistent label conventions and the original CNPs assumed `app.kubernetes.io/name=<service>` for everything. Real labels observed 2026-05-10:
   * MongoDB pods: `app.kubernetes.io/name=nomad`, `app.kubernetes.io/component=mongodb` (Bitnami chart re-labels with the release name).
   * Elasticsearch-master pods: `app=elasticsearch-master`, `release=nomad-oasis`, `chart=elasticsearch` — OLD-style labels, NO `app.kubernetes.io/*` at all.
   * PostgreSQL pods: `app.kubernetes.io/name=postgresql`, `app.kubernetes.io/component=primary` (Bitnami).
   * Temporal pods (frontend/history/matching/worker/admintools/schema): `app.kubernetes.io/name=temporal` (NOT `temporalserver`).
   * NOMAD app/worker/proxy: `app.kubernetes.io/name=nomad`, with `component=app|worker|proxy`.

   Wrong selector → CNP selects zero pods → under `policyEnforcementMode=default` the destination receives no policy AND any egress allow-rule on a *source* CNP that points at the same wrong label matches no destination, so traffic is dropped at egress with `Policy denied`. Verify selectors before merging: `kubectl get pod -n nomad-oasis <real-pod-name> -o jsonpath='{.metadata.labels}'` and match exactly. Discovered 2026-05-10 — Hubble drop `nomad-oasis-app:* (ID:2742) <> elasticsearch-master:9200 Policy denied DROPPED` was the canonical symptom.

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
kubectl kustomize new-infra/k8s/zeek | sed "s/\${AWS_ACCOUNT_ID}/845517756853/g" | kubectl apply -f -
kubectl kustomize new-infra/k8s/suricata | sed "s/\${AWS_ACCOUNT_ID}/845517756853/g" | kubectl apply -f -
kubectl kustomize new-infra/k8s/wazuh-agent | sed "s/\${AWS_ACCOUNT_ID}/845517756853/g" | kubectl apply -f -
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
- **ESO ClusterSecretStore `WebIdentityErr` / STS timeout**: `toFQDNs` is broken in Cilium ENI mode (see Cilium ENI Mode section). The `external-secrets-netpol.yaml` already has the fix: `toCIDRSet` for STS VPC endpoint IPs + `toEntities: world` for Secrets Manager. If these IPs change, update the CIDR rules in `new-infra/k8s/system-netpols/external-secrets-netpol.yaml`.
- **State health check false-negative (pipefail)**: With `set -euo pipefail`, piping `terraform state list | grep` fails if `terraform state list` exits non-zero (Helm provider can't connect to K8s before kubeconfig is configured) — even when grep would find the sentinel. Fix: capture `STATE_LIST=$(terraform state list 2>/dev/null || true)` then grep the variable. Already fixed in `terraform-deploy.yml` and `terraform-state-recovery.yml`.
- **Terraform state drift after cancelled apply**: Use `terraform-state-recovery.yml` (workflow_dispatch) to re-import missing resources. The `import_if_missing` helper is idempotent. Always run dry_run=true first. Never delete S3 state versions.

---

## Pre-Production Gaps

**See [`PRE_PROD_GAPS.md`](PRE_PROD_GAPS.md) for the full list of known, accepted gaps that MUST be resolved before any production deployment.**

Summary of open gaps:
- **GAP-001**: Wazuh agent→manager TCP 1514 is unencrypted — enable `secure` mode with self-signed CA
- **GAP-002**: MISP sidecars use `curl -k` — certificate validation disabled, MITM risk
- **GAP-003**: No container image signing or admission control — supply chain unverified
- **GAP-004**: Wazuh all-in-one is a single point of failure for the entire telemetry pipeline
- **GAP-005**: Shuffle EC2 has no SSM instance profile — no out-of-band access
- **GAP-006**: No Wazuh active response configured — detection only, no automated enforcement
- **GAP-007**: No certificate rotation plan for when GAP-001/002 are fixed
- **GAP-008**: No OpenSearch S3 snapshot repository — historical alerts lost on EC2 failure, no compliance archive

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
- **Self-signed cert**: MISP uses a self-signed cert. Sidecars use `curl -k` — see **GAP-002** in `PRE_PROD_GAPS.md`.

### Shuffle (EC2 — bc-ctrl)
- **Moved off EKS** — now `shuffle-ec2` (t3.large, Ubuntu 24.04, private subnet) in bc-ctrl, running Shuffle v2.2.0 via Docker Compose.
- Requires `vm.max_map_count=262144` for OpenSearch (set in user_data via sysctl).
- No SSM instance profile registered yet — access only via VPC-internal routing.
- EKS Helm release remains commented out in `helm-security.tf`.

### Cilium ENI Mode
- aws-node DaemonSet is kept running but neutered via `nodeSelector: non-existent=true` on the original aws-node pods — Cilium takes over IP management completely.
- Do NOT switch to chaining mode. ENI mode is stable.
- **`toFQDNs` is broken in this ENI deployment**: DNS proxy intercepts queries and populates the FQDN cache, but CIDR identities are never inserted into the ipcache for resolved IPs (VPC-internal or public). The compound `fqdn:*.amazonaws.com + reserved:world` BPF rule never fires. Use `toEntities: world` for public endpoints and `toCIDRSet` only for VPC endpoints whose IPs are verified stable. Phase J and any future FQDN-based egress rules MUST use this workaround.
- **STS VPC endpoint CIDR rule: removed**. The STS VPC endpoint IPs change on every cluster/VPC rebuild, making any pinned `toCIDRSet` rule silently stale after a rebuild. All system-netpols (`external-secrets-netpol.yaml`, `ebs-csi-netpol.yaml`, `efs-csi-netpol.yaml`, `alb-controller-netpol.yaml`) rely solely on `toEntities: world:443` for STS/IRSA — traffic routes via fck-nat to the public STS endpoint. If you want to re-add the VPC endpoint optimization after a rebuild, verify the new IPs first: `aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=<bc-prd-vpc-id>" "Name=description,Values=*sts*" --query "NetworkInterfaces[*].PrivateIpAddress" --region eu-central-1`
- **EC2 VPC endpoint IPs** (retained in `ebs-csi-netpol.yaml`): `10.30.10.135/32`, `10.30.11.26/32`. These were validated stable in commit 922f483 and are a different endpoint from STS — do not remove without re-verifying.
- **Cilium health endpoint**: Port 4240. Inter-node health probes from `remote-node` require explicit CNP (`cilium-health-netpol.yaml` in system-netpols). EBS CSI node needs IMDS egress (`169.254.169.254/32:80`) — use `toCIDRSet` for link-local address.

---

## Current Rollout Status (see `SECURITY_STACK_ROLLOUT_PLAN.md` for details)

| Phase | Status | Summary |
|-------|--------|---------|
| Phase A | Done | Suricata memory tuning (requests 2Gi → 512Mi) |
| Phase B | Done | Hubble relay + UI running; B.8–B.12 all validated green |
| Phase C | Superseded | bc-ctrl EKS removed; Wazuh/MISP migrated to EC2 |
| Phase D | Done | CNPs applied; `policyEnforcementMode=default`; explicit CNPs are the authoritative deny layer; ESO secrets syncing |
| Phase E | Superseded | Pipeline already rewritten with proper structure |
| Phase F | Not started | eks-security-stack module — blocked on G+D stable |
| Phase G | Done | kube-proxy removed; kubeProxyReplacement=true deployed and validated — CI run 25604876697 |
| Phase H | Done (H.5 pre-existing bug) | WireGuard active (validated via `cilium encrypt status`). H.5 Wazuh auth is a pre-existing bug, out of scope |
| Phase I | Blocked | Hubble UI permanent ingress — blocked on ACM cert |
| Phase J | Fix pending CI | J.5 revealed 2 CNP gaps: ebs-csi IMDS + cilium-health port 4240. Fixes in system-netpols, pending next CI run |
| Phase K | Deferred | Host firewall — do NOT start on bc-prd until D+G+H complete |

### NOMAD Oasis + Local Keycloak (2026-05-11/12)

**Full cold-start hardening landed.** Pipeline runs from empty AWS state → green end-to-end with zero manual steps. See `SESSION_2026-05-11_KEYCLOAK_MIGRATION.md` for the full chronicle of ~22 commits and their root causes.

| Component | Status |
|---|---|
| Cilium operator IRSA + EC2 ENI perms (incl. `DescribeRouteTables`) | Working |
| AWS_REGION + cluster.name on cilium-operator (avoids EC2 API timeout) | Set in helm-security.tf |
| ALB controller `enableServiceMutatorWebhook: false` | Set (avoids Service-create webhook timeouts) |
| Auto-bounce kube-system / ESO / Temporal / cilium-operator | In workflow Stage 2a, 2b, 2d heal steps |
| Keycloak 24.0.5 via codecentric/keycloakx 7.1.9 sub-chart | Deployed + healthy |
| Realm `nomad-oasis` with `testuser`/`testpass123` auto-imported | ConfigMap at `k8s/nomad-oasis/keycloak-realm-import-configmap.yaml` |
| Keycloak DB init Job (idempotent psql `\gexec`) | Step A in workflow |
| nginx proxy `/auth/` overlay | ConfigMap at `k8s/nomad-oasis/nomad-proxy-configmap-patch.yaml`, re-applied in Step B |
| Backend OIDC discovery + token validation NOMAD ↔ Keycloak | **Working** |
| **Browser OAuth login form-submit** | **NOT WORKING** — see "Open Issues" below |

### Open issue: browser login on dev-path

Browser auth flow gets the Keycloak login form but the form-submit POST fails with `"Cookie not found. Please make sure cookies are enabled in your browser."` (HTTP 400 from `/auth/realms/nomad-oasis/login-actions/authenticate`).

**Root cause**: Keycloak 24+ defaults session cookies to `SameSite=None`, which the browser only accepts paired with `Secure`. Our dev-path is plain HTTP (port-forward → nginx → Keycloak all HTTP), so the browser silently drops the `Secure`-flagged cookies. Removed `KC_PROXY=edge` didn't help — Keycloak still emits `SameSite=None` defaults.

**Fix paths** (none implemented yet):
1. **Production path (recommended)** — ALB Ingress + ACM cert + Route53 zone. Real HTTPS, real domain. `Secure` cookies work natively. ~$16/mo for ALB + $0.50/mo Route53.
2. **Keycloak SPI customization** to disable `SameSite=None` defaults. Not exposed via env in Keycloak 24; would need a downstream fork.
3. **Pin older Keycloak** (e.g., 22.x) that defaults to `SameSite=Lax`. Drifts from upstream support.

**Workaround for now**: NOMAD anonymous browsing works fine without login (About, public data browsing). Useful for verifying deployment health.

### Cold-start gotchas baked into code (don't undo these)

These all surfaced today and have fixes committed. Removing them will re-break cold-start:

| Gotcha | Fix location |
|---|---|
| SM secret 7-day soft-delete blocks re-create | `recovery_window_in_days = 0` on all `nomad-oasis/*` secrets |
| TF `for_each` on apply-time-unknown module outputs | `count = <static>` instead (see `efs-nomad.tf`) |
| State guard fails on true cold-start | Probes AWS for EKS cluster before fail-loud (see `terraform-deploy.yml` state health step) |
| Cilium operator IRSA Helm path | `serviceAccounts.operator.annotations` (NOT singular) |
| Cilium operator warm-update missing IRSA | Explicit `kubectl rollout restart deploy/cilium-operator` after Cilium Helm |
| ALB controller mservice webhook blocks Service creates on cold-start | `enableServiceMutatorWebhook: false` |
| ESO cert-controller readiness probe never passes (chart bug) | Best-effort wait with `|| echo` |
| Tetragon CRD wait in Stage 2a (CRD comes in 2b) | Removed from Stage 2a wait |
| `kubectl rollout status` waits on slow old-pod termination | Use `kubectl wait --for=condition=available` for Deployments |
| Keycloak chart hardcodes `KC_CACHE_STACK=jdbc-ping` (invalid in KC24) | Override `cache.stack: kubernetes` |
| Keycloak 24 has no separate management port (chart targets `http-internal`) | TCP socket probes on `http` port |
| Keycloak `KC_HOSTNAME` must be hostname-only (not URL) | `localhost` not `http://localhost` |
| Realm-import ConfigMap mounted by Keycloak STS, applied too late by kustomize | Pre-applied in Stage 2c |
| nginx proxy `/auth/` upstream caches DNS at startup | nginx config applied after Keycloak Service exists; pipeline restarts proxy in Step B |
| Cilium policy DROPPED proxy → keycloak:8080 | Explicit `nomad-proxy-netpol` egress to keycloak |
| Keycloak StatefulSet rolling-update stalls if old pod won't Ready | Step C force-deletes pod when `controller-revision-hash` != `updateRevision` |

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
| AWS Account | `845517756853` |
| Region | `eu-central-1` |
| TF State Bucket | `bc-uatms-terraform-state` |
| Wazuh Snapshots + Scripts | `bc-uatms-wazuh-snapshots` |
| VPC Flow Logs | `bc-vpcflow-logs` |
| CloudTrail Logs | `bc-cloudtrail-logs` |
| GuardDuty Logs | `bc-guardduty-logs` |
| Config Logs | `bc-config-logs` |
| CI Role | `arn:aws:iam::845517756853:role/GitHubActionsDeployRole` |
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

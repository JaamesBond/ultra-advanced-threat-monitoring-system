# Big Chemistry XDR "Brain/Data" (v8) Threat Monitoring System

## 🗺 System Intelligence & Resource Map
For AI agents and engineers navigating this repository:

### 1. Core Resource Paths
- **Environments**: `new-infra/environments/` (Root modules for `bc-ctrl` and `bc-prd`).
- **Shared Infrastructure**: `new-infra/shared/` (S3 state, ECR Cache, Global Runners).
- **Reusable Modules**: `new-infra/modules/` (VPC, EKS Addons, Peering logic).
- **K8s Manifests**: `new-infra/k8s/` (Wazuh, Zeek, Suricata, Tetragon, Nomad).
- **Network Diagram**: `new-infra/docs/v8-network-diagram.drawio`.
- **Rollout Tracker**: `SECURITY_STACK_ROLLOUT_PLAN.md`.

### 2. IAM Role Directory
- **CI/CD Role**: `arn:aws:iam::845517756853:role/GitHubActionsDeployRole` (OIDC-assumed by GitHub).
- **Runner Instance Role**: `github-runner-role` (Used by the host EC2 in `bc-ctrl`).
- **EKS Admin**: Both the above roles MUST be in EKS `access_entries` with `AmazonEKSClusterAdminPolicy`.

## 🏗 Architecture Highlights (v8)
The system uses a **Brain/Data** hub-spoke model via VPC Peering (no Transit Gateway).

- **bc-ctrl (The Brain)**: `10.0.0.0/16`. Control plane, EC2-only workloads.
    - **Wazuh-ctrl** (`t3.xlarge`): All-in-one Manager + Indexer + Dashboard (v4.14.4).
    - **MISP-ctrl** (`t3.large`): Threat intelligence platform.
    - **Shuffle-ec2** (`t3.large`): SOAR v2.2.0 (Docker Compose on Ubuntu 24.04).
    - **GitHub Runner** (`t3.small`): Self-hosted runner for production-plane jobs.
    - **fck-nat-shared** (`t4g.nano`): NAT for management subnets.
- **bc-prd (The Data Plane)**: `10.30.0.0/16`. Production EKS cluster.
    - **EKS Cluster (v1.35)**: `bc-uatms-prd-eks` with 2× `t3.medium` nodes.
    - **Security Stack**: Cilium (ENI mode), Falco (modern_ebpf), Tetragon (SIGKILL).
    - **fck-nat-prd**: Dedicated local NAT for EKS worker nodes.
    - **VPC Endpoints**: Full suite (ECR, S3, STS, etc.) for private cluster access.

## 🛡 Security Standards & Versions
Mandatory on every EKS cluster in the `bc-*` namespace:

| Component | Version | Purpose |
|-----------|---------|---------|
| **Cilium** | 1.19.3 | CNI (ENI mode), eBPF proxy, WireGuard encryption, `policyEnforcementMode=always`. |
| **Falco** | 8.0.2 | Runtime syscall auditing via `modern_ebpf` driver. |
| **Tetragon** | 1.6.1 | Process-level enforcement (SIGKILL for `nc`, `nmap`). |
| **Wazuh Agent**| 4.14.4 | Ships telemetry from Suricata/Zeek/Falco to Manager. |
| **Suricata** | 7.0.7 | Network IDS/IPS DaemonSet with MISP sync sidecars. |
| **Zeek** | 7.0.5 | Network NSM DaemonSet with MISP Intel sync sidecars. |

## 📊 Telemetry Pipeline
1. **Sensors**: Suricata (IDS), Zeek (NSM), and Falco (Runtime) write logs to node `hostPath`.
2. **Shipper**: `wazuh-agent` DaemonSet reads these logs and ships via TCP 1514 (WireGuard encrypted).
3. **Ingest**: `wazuh-manager` on `bc-ctrl` indexes data into OpenSearch for Dashboard visualization.
4. **Intelligence**: MISP IOCs are synced every hour to Zeek (Intel format) and Suricata (Rule format).

## 🛠 Lessons Learned (AI Playbook)
### 1. Networking: The Peering Trap
VPC Peering is **not transitive**. Traffic from `bc-prd` cannot reach the internet through `bc-ctrl`.
- **Rule**: Every VPC MUST have a local `fck-nat` or NAT GW.
- **Rule**: Private subnets must point `0.0.0.0/0` to the local NAT ENI.

### 2. IAM: The EKS Access Conflict
NEVER use `enable_cluster_creator_admin_permissions = true`. It causes 409 conflicts.
- **Fix**: Use explicit `access_entries` for all managing roles.

### 3. Compute: The Resource Wall
The security stack (Cilium/Falco/Tetragon) is resource-heavy.
- **Constraint**: `t3.small` pod limit (11) is too low for the stack.
- **Fix**: Use `t3.medium` (17 pod limit) at a minimum.

### 4. Wazuh: Version & Auth
- **Version**: Pin to `4.14.4`. The `4.9.x` repo is retired (403 Forbidden).
- **Auth**: Manager uses Secrets Manager password. Agents use password-less enrollment (authd).

### 5. Cilium: ENI Mode & FQDNs
- **ENI Mode**: Stable, replaces `aws-node`. Do NOT switch to chaining mode.
- **FQDN Gap**: `toFQDNs` is broken in ENI mode. Use `toEntities: world` + `toCIDRSet` as a workaround.
- **NetPols**: `policyEnforcementMode=always` requires explicit CNPs for EVERYTHING (CoreDNS, STS, etc.).

## 🧪 Testing & Verification
- **Victim Scripts**: `new-infra/scripts/victim-install-*.sh` for simulation.
- **Hubble**: Use `cilium status` and `hubble observe` to verify flows.
- **Falco/Tetragon**: Check logs for JSON events.
- **External Secrets**: Ensure `externalsecret` resources are syncing from AWS Secrets Manager.

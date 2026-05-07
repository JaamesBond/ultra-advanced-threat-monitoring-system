# Big Chemistry XDR "Brain/Data" (v8) Threat Monitoring System

## Project Overview
This repository contains the Terraform and Kubernetes infrastructure for **Big Chemistry's XDR v8 security system**. The architecture is a simplified, cost-optimized "Brain/Data" model consisting of two AWS VPCs (`bc-ctrl` and `bc-prd`) in `eu-central-1` connected via **VPC Peering**.

### 🗺 System Intelligence & Resource Map
For AI agents and engineers navigating this repository:

#### 1. Core Resource Paths
- **Environments**: `new-infra/environments/` (Root modules for `bc-ctrl` and `bc-prd`).
- **Shared Infrastructure**: `new-infra/shared/` (S3 state, ECR Cache, Global Runners).
- **Reusable Modules**: `new-infra/modules/` (VPC, EKS Addons, Peering logic).
- **K8s Manifests**: `new-infra/k8s/` (Wazuh, Zeek, Suricata, MISP).
- **Network Diagram**: `new-infra/docs/v8-network-diagram.drawio`.

#### 2. IAM Role Directory
- **CI/CD Role**: `arn:aws:iam::286439316079:role/GitHubActionsDeployRole` (OIDC-assumed by GitHub).
- **Runner Instance Role**: `github-runner-role` (Used by the host EC2 in `bc-ctrl`).
- **EKS Admin**: Both the above roles MUST be in EKS `access_entries` with `AmazonEKSClusterAdminPolicy`.

### 🏗 Architecture Highlights (v8)
- **VPC Peering**: Replaces Transit Gateway for lower cost. **Note**: Transitive routing is NOT supported; each VPC has its own local egress.
- **bc-ctrl (The Brain)**:
    - **EKS Cluster (v1.35)**: `bc-uatms-ctrl-eks` with `t3.xlarge` nodes hosting Wazuh (Manager, Indexer, Dashboard) and an Internal NLB for VPC Peering traffic.
    - **fck-nat-shared** (`t4g.nano`): Handles NAT for management subnets.
    - **GitHub Actions Runner**: Self-hosted `t3.small` with Node.js, Terraform, and kubectl pre-installed.
    - **Security Tools**: Dedicated `t3.nano` Docker host.
- **bc-prd (The Data Plane)**:
    - **EKS Cluster (v1.35)**: 2x `t3.medium` nodes. **Warning**: eBPF stack requires >2GB RAM; `t3.small` will fail due to pod limits (11).
    - **fck-nat-prd**: Dedicated local NAT for EKS worker nodes.
    - **VPC Endpoints**: Full suite (ECR, S3, STS, etc.) to ensure cluster control plane access.
    - **Security Stack**: Cilium (ENI mode), Falco (eBPF), Tetragon (SIGKILL enforcement).

### Security Standards (Mandatory for ALL EKS Clusters)
To ensure consistent observability and zero-day protection, the following stack MUST be deployed on every EKS cluster:
- **Cilium**: L3/L4/L7 Network security and identity.
- **Falco**: Real-time syscall auditing and alerting.
- **Tetragon**: Real-time process and syscall enforcement (SIGKILL).

## Building and Running
1. **Control Plane (`bc-ctrl`)**: Deploy first to establish the hub and runner.
2. **Production Plane (`bc-prd`)**: Deploy second; depends on `bc-ctrl` for peering acceptance.

## 🛠 Lessons Learned (AI Playbook)
To prevent common EKS/Networking failures in this environment:

### 1. Networking: The Peering Trap
VPC Peering is **not transitive**. Traffic from `bc-prd` cannot reach the internet through a NAT in `bc-ctrl`. 
- **Rule**: Every VPC requiring internet egress MUST have a local `fck-nat` or NAT GW.
- **Rule**: Private subnets must point `0.0.0.0/0` to the local NAT ENI, NOT the peering connection.

### 2. IAM: The EKS Access Conflict
NEVER use `enable_cluster_creator_admin_permissions = true` in CI/CD. 
- **Conflict**: Local user (e.g., `Matei`) vs. CI role (`GitHubActionsDeployRole`) creates `409 ResourceInUse` errors.
- **Fix**: Disable auto-permissions and use explicit `access_entries` for all managing roles.

### 3. Compute: The Resource Wall
The security stack (Cilium/Falco/Tetragon) is resource-heavy.
- **Constraint**: `t3.small` has a hard limit of 11 pods.
- **Fix**: Use `t3.medium` (17 pod limit) at a minimum.

### 4. Runner: The Actions Dependency
GH Actions requires Node.js on the host.
- **Fix**: Ensure `nodejs`, `git`, `jq`, `libicu`, `terraform`, and `kubectl` are in the runner's `user_data`.

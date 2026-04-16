# Big Chemistry XDR "Brain/Data" (v8) Threat Monitoring System

## Project Overview
This repository contains the Terraform and Kubernetes infrastructure for **Big Chemistry's XDR v8 security system**. The architecture is a simplified, cost-optimized "Brain/Data" model consisting of two AWS VPCs (`bc-ctrl` and `bc-prd`) in `eu-central-1` connected via **VPC Peering**.

### Architecture Highlights (v8)
- **VPC Peering**: Replaces Transit Gateway for lower cost. **Note**: Transitive routing is NOT supported; each VPC has its own local egress.
- **bc-ctrl (The Brain)**:
    - **fck-nat-shared** (`t4g.nano`): Handles NAT for management subnets.
    - **GitHub Actions Runner**: Self-hosted `t3.small` with Node.js, Terraform, and kubectl pre-installed.
    - **Security Tools**: Dedicated `t3.nano` Docker host.
- **bc-prd (The Data Plane)**:
    - **EKS Cluster (v1.35)**: 2x `t3.medium` nodes. **Warning**: eBPF stack requires >2GB RAM; `t3.small` will fail due to pod limits (11) and memory pressure.
    - **fck-nat-prd**: Dedicated local NAT for EKS worker nodes.
    - **VPC Endpoints**: Full suite (ECR, S3, STS, etc.) to ensure EKS control plane access is independent of NAT status.
    - **Security Stack**: Cilium (ENI mode), Falco (eBPF), Tetragon (SIGKILL enforcement).

### Security Standards (Mandatory for ALL EKS Clusters)
To ensure consistent observability and zero-day protection across the XDR system, the following eBPF stack MUST be deployed on every EKS cluster:
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
- **Fix**: Deploy a local `fck-nat` in every VPC that requires internet egress.
- **Fix**: Deploy VPC Endpoints in private VPCs to unblock EKS node registration.

### 2. IAM: The EKS Access Conflict
The EKS module's `enable_cluster_creator_admin_permissions` is dangerous in CI/CD. It uses the ARN of the role/user that runs the apply. If you run locally as `User A` and then in GH Actions as `Role B`, you will get `409 ResourceInUse` errors.
- **Fix**: Set `enable_cluster_creator_admin_permissions = false` and use **explicit** `access_entries` for all roles.

### 3. Compute: The Resource Wall
Cilium + Falco + Tetragon + CloudWatch Agent = ~12-14 pods per node.
- **Constraint**: `t3.small` has a hard limit of 11 pods.
- **Fix**: Use `t3.medium` (17 pod limit) at a minimum for worker nodes.

### 4. Runner: The Actions Dependency
GH Actions host-side logic (checkout, etc.) requires Node.js.
- **Fix**: Ensure `nodejs`, `git`, and `jq` are in the runner's `user_data`.

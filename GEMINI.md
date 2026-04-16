# Big Chemistry XDR "Brain/Data" (v8) Threat Monitoring System

## Project Overview
This repository contains the Terraform and Kubernetes infrastructure for **Big Chemistry's XDR v8 security system**. The architecture is a simplified, cost-optimized "Brain/Data" model consisting of two AWS VPCs (`bc-ctrl` and `bc-prd`) in `eu-central-1` connected via **VPC Peering**.

### Architecture Highlights (v8)
- **VPC Peering**: Replaces Transit Gateway for lower cost and latency. Direct bi-directional routing between Control and Production planes.
- **bc-ctrl (The Brain)**:
    - Hosts the centralized security tools and management stack.
    - **fck-nat (ARM64)**: Provides a cost-effective NAT hub for the Control Plane.
    - **GitHub Actions Runner**: A self-hosted `t3.small` instance for secure, private-network deployments.
    - **Security Tools VM**: A dedicated `t3.nano` instance for Docker-based security services.
- **bc-prd (The Data Plane)**:
    - **EKS Cluster (v1.35)**: Strictly **2 worker nodes** (`t3.small`) hosting workload applications.
    - **fck-nat (Local)**: Dedicated internet egress for worker nodes to pull images and updates.
    - **Security Stack**: Deep monitoring via **Cilium CNI (ENI mode)**, **Falco (eBPF syscall auditing)**, and **Tetragon (SIGKILL enforcement)**.
    - **VPC Endpoints**: Ensures the EKS cluster remains operational even during NAT/Peering maintenance.

## Building and Running
The infrastructure deployment follows a two-stage bootstrap process to handle peering dependencies.

### Deployment Order
1. **Control Plane (`bc-ctrl`)**
   ```bash
   cd new-infra/environments/bc-ctrl/eu-central-1 && terraform init && terraform apply
   ```
2. **Production Plane (`bc-prd`)**
   ```bash
   cd new-infra/environments/bc-prd/eu-central-1 && terraform init && terraform apply
   ```

*Note: The GitHub Runner in `bc-ctrl` is required to reach the private EKS API in `bc-prd` for Helm deployments.*

## Development Conventions
- **Cost-First Design**: Always use `fck-nat` and minimal instance types (`t3.nano/micro/small`) for testing.
- **Resource Pinning**: EKS node count is strictly pinned to 2 nodes. DO NOT upscale without approval.
- **Transitive Routing Limitation**: Remember that VPC Peering does NOT support transitive routing; each VPC must have its own egress path or local NAT.
- **Graphify Tooling**: 
  - ALWAYS use `/graphify query "<concept>"` to understand the architecture.
  - ALWAYS run `/graphify new-infra --update` after modifications to keep the cache fresh.

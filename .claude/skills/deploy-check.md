---
name: deploy-check
description: Pre-deployment validation checklist for terraform apply and kubectl deployments to bc-ctrl and bc-prd environments
---

# Deploy Check — Big Chemistry XDR

Pre-flight checklist before running `terraform apply` or deploying K8s manifests. Validates configuration, dependencies, and readiness.

## Procedure

### Step 1: Determine Deploy Target

Which environment? Check the user's intent:
- `bc-ctrl` — Brain/control plane (Wazuh Manager stack)
- `bc-prd` — Data/production plane (security agents)
- Both — Full deploy (ctrl MUST go first)

### Step 2: Terraform Validation

Read the target environment's TF files and check:

**For bc-ctrl (`new-infra/environments/bc-ctrl/eu-central-1/`):**
- [ ] `locals.tf`: region = `eu-central-1`, env = `ctrl`, vpc_cidr = `10.0.0.0/16`
- [ ] `vpc.tf`: fck-nat has `source_dest_check = false`, MASQUERADE in user_data
- [ ] `eks.tf`: `enable_cluster_creator_admin_permissions = false`, access_entries defined
- [ ] `eks.tf`: node SG allows ingress from `10.30.0.0/16` on 1514/1515
- [ ] `vm.tf`: runner has PAT secret reference, nodejs/terraform/kubectl installed
- [ ] `route53.tf`: private zone associated with both VPCs

**For bc-prd (`new-infra/environments/bc-prd/eu-central-1/`):**
- [ ] `locals.tf`: region = `eu-central-1`, env = `prd`, vpc_cidr = `10.30.0.0/16`
- [ ] `vpc.tf`: fck-nat has `source_dest_check = false`, MASQUERADE for `0.0.0.0/0`
- [ ] `vpc.tf`: VPC endpoints enabled (S3, EC2, ECR, STS, SSM, CW Logs, KMS)
- [ ] `vpc.tf`: peering module references correct peer VPC ID
- [ ] `eks.tf`: workers = `t3.medium`, min/max/desired = 2
- [ ] `eks.tf`: `enable_cluster_creator_admin_permissions = false`
- [ ] `helm-security.tf`: Cilium + Falco + Tetragon all present

### Step 3: K8s Manifest Validation

If deploying K8s manifests:

**Wazuh (bc-ctrl):**
- [ ] `k8s/wazuh/kustomization.yaml` includes manager, indexer, dashboard
- [ ] ExternalSecret CRDs reference `bc/*` secrets that exist in Secrets Manager
- [ ] Certificate CRDs defined for TLS
- [ ] Manager Service type = LoadBalancer with NLB annotations

**Wazuh Agent (bc-prd):**
- [ ] Agent ConfigMap points to `wazuh-manager.bc-ctrl.internal`
- [ ] DaemonSet has correct namespace (`wazuh`)

**Zeek/Suricata (bc-prd):**
- [ ] DaemonSets have `hostNetwork: true`
- [ ] Security capabilities: NET_RAW, NET_ADMIN
- [ ] ConfigMaps have valid configs

### Step 4: Dependency Check

**If deploying bc-prd after bc-ctrl:**
- [ ] bc-ctrl EKS is running and accessible
- [ ] Wazuh Manager pods are Ready
- [ ] NLB is provisioned and has DNS name
- [ ] Route53 record `wazuh-manager.bc-ctrl.internal` resolves

**If deploying CRD-dependent resources:**
- [ ] Cilium Helm release deployed before CiliumNetworkPolicy
- [ ] Tetragon Helm release deployed before TracingPolicy
- [ ] cert-manager deployed before Certificate CRDs
- [ ] external-secrets deployed before ExternalSecret CRDs

### Step 5: Pipeline Alignment

If deploying via GitHub Actions:
- [ ] Changes committed and pushed to `main`
- [ ] `terraform-deploy.yml` workflow matches current TF structure
- [ ] Self-hosted runner is online (for bc-prd stage)
- [ ] OIDC role trust policy allows the repository/branch

### Step 6: Report

```
## Deploy Check: [bc-ctrl / bc-prd / both]

### Terraform: [READY / NOT READY]
[List any issues]

### K8s Manifests: [READY / NOT READY / N/A]
[List any issues]

### Dependencies: [MET / NOT MET]
[List any unmet dependencies]

### Pipeline: [ALIGNED / MISALIGNED / MANUAL]
[List any pipeline issues]

### Verdict: [GO / NO-GO]
[Required actions before deploy]
```

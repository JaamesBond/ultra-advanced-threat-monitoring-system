---
name: tf-review
description: Validate Terraform changes against Big Chemistry XDR guardrails, cost constraints, security posture, and architectural standards before apply
---

# Terraform Review — Big Chemistry XDR

Review all pending or proposed Terraform changes against project guardrails. This skill should be invoked before any `terraform apply` or before merging Terraform PRs.

## Procedure

### Step 1: Identify Changes

Determine what changed:
- If reviewing a PR: `git diff main...HEAD -- 'new-infra/**/*.tf'`
- If reviewing unstaged work: `git diff -- 'new-infra/**/*.tf'`
- If reviewing a specific file: read the file directly

### Step 2: Guardrail Checks (BLOCKERS)

Check every changed file against these absolute rules. Any violation = BLOCK.

| # | Guardrail | Check For |
|---|-----------|-----------|
| 1 | No Managed NAT | `aws_nat_gateway` resource must NOT exist |
| 2 | No Transit Gateway | `aws_ec2_transit_gateway` must NOT exist |
| 3 | No transitive routing | Private RT routes must NOT point to peer VPC's NAT for 0.0.0.0/0 |
| 4 | Explicit EKS access | `enable_cluster_creator_admin_permissions` must be `false` |
| 5 | bc-prd workers = t3.medium | `instance_types` in bc-prd node groups must be `["t3.medium"]` |
| 6 | bc-ctrl workers = t3.xlarge | `instance_types` in bc-ctrl node groups must be `["t3.xlarge"]` |
| 7 | fck-nat source_dest_check | Must be `false` on all fck-nat instances |
| 8 | fck-nat MASQUERADE | user_data must contain MASQUERADE iptables rule |
| 9 | Mandatory security stack | bc-prd must have helm_release for cilium, falco, AND tetragon |
| 10 | VPC endpoint SG | Must restrict to HTTPS (443) from VPC CIDR only |

### Step 3: Cost Impact Analysis

For each new or modified resource:
1. Estimate monthly cost delta
2. Flag if total monthly cost increase > $10 without justification
3. Check for cheaper alternatives (t4g vs t3, Gateway vs Interface endpoint, etc.)

### Step 4: Security Review

For each change:
- [ ] Security group changes: is ingress over-broad?
- [ ] IAM changes: is policy scoped to minimum required?
- [ ] New public access: is it justified?
- [ ] Secret handling: encrypted at rest and in transit?
- [ ] EKS access entries: only known principals?

### Step 5: Architectural Consistency

- [ ] Module versions match environment (v20 args in bc-prd, v21 args in bc-ctrl)
- [ ] Tags include all `common_tags` fields (Project, Environment, Customer, IACTool)
- [ ] Resource naming follows convention: `{platform_name}-{env}-{resource}`
- [ ] State dependencies (remote_state, outputs) still valid

### Step 6: Report

Output findings in this format:

```
## TF Review: [files reviewed]

### Guardrails: [PASS/BLOCK]
[List any violations]

### Cost Impact: [+$X/month]
[Itemized cost changes]

### Security: [PASS/WARN]
[List any concerns]

### Architecture: [PASS/WARN]
[List any inconsistencies]

### Verdict: [APPROVE / NEEDS CHANGES]
[Summary and required actions]
```

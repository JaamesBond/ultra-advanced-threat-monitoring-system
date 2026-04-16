---
name: security-audit
description: Audit the full XDR security stack configuration — Cilium, Falco, Tetragon, Wazuh, Suricata, Zeek — for completeness, misconfigurations, and gaps
---

# Security Audit — Big Chemistry XDR

Comprehensive audit of the security monitoring and enforcement stack. Run periodically or before any deployment.

## Procedure

### Step 1: Terraform Security Resources

Read and validate these files:
- `new-infra/environments/bc-prd/eu-central-1/helm-security.tf` — Cilium, Falco, Tetragon Helm
- `new-infra/environments/bc-prd/eu-central-1/eks.tf` — Node SG rules, access entries
- `new-infra/environments/bc-ctrl/eu-central-1/eks.tf` — Wazuh node SG, cross-VPC rules
- `new-infra/environments/bc-ctrl/eu-central-1/vm.tf` — Runner IAM, security tools EC2

Check:
- [ ] Cilium: `eni.enabled=true`, `ipam.mode=eni`, `routingMode=native`
- [ ] Falco: `driver.kind=ebpf` (NOT kernel module)
- [ ] Tetragon: deployed to kube-system
- [ ] All three present in bc-prd (mandatory stack)

### Step 2: K8s Manifest Security

Read and validate:
- `new-infra/k8s/wazuh/` — All components
- `new-infra/k8s/suricata/` — DaemonSet, configs
- `new-infra/k8s/zeek/` — DaemonSet, configs
- `new-infra/k8s/misp/` — Deployment, StatefulSet

Check:
- [ ] ExternalSecret CRDs reference valid secret paths (`bc/*`)
- [ ] DaemonSets that need hostNetwork have it set
- [ ] SecurityContext: only grant needed capabilities (NET_RAW, NET_ADMIN for IDS)
- [ ] Resource limits set on all containers (prevent resource exhaustion)
- [ ] No `privileged: true` unless absolutely required
- [ ] Service accounts don't have unnecessary cluster-wide permissions

### Step 3: Network Segmentation

Check:
- [ ] bc-ctrl node SG: ingress from bc-prd limited to 1514/1515 (Wazuh ports)
- [ ] bc-prd node SG: self-ingress only, plus egress all (for NAT)
- [ ] VPC endpoint SG: HTTPS from VPC CIDR only
- [ ] fck-nat SG: ingress from internal CIDRs, egress all
- [ ] No SG with `0.0.0.0/0` ingress (except fck-nat which has public IP)
- [ ] VPC peering routes only in private route tables

### Step 4: IAM Audit

Check:
- [ ] GitHub Runner: still has AdministratorAccess (flag as HIGH risk)
- [ ] Pod Identity roles: LBC, external-secrets, external-dns scoped correctly
- [ ] external-secrets: read-only on `bc/*` secrets only
- [ ] external-dns: Route53 changes scoped to specific zone ARNs
- [ ] fck-nat/security-tools: only SSM managed instance core
- [ ] No IAM policies with `Resource: "*"` and `Action: "*"`

### Step 5: Missing Controls

Check for gaps:
- [ ] CiliumNetworkPolicy CRDs exist and are applied (default deny + allow lists)
- [ ] Tetragon TracingPolicy CRDs exist for enforcement
- [ ] Falco custom rules beyond defaults
- [ ] Suricata rule updates / ET ruleset integration
- [ ] Log forwarding from Falco/Tetragon to Wazuh or CloudWatch
- [ ] Wazuh active response rules configured
- [ ] MISP feeds configured and active

### Step 6: Report

```
## Security Audit Report

### Stack Completeness: [X/7 tools deployed]
| Tool | Status | Issues |
|------|--------|--------|
| Cilium | ... | ... |
| Falco | ... | ... |
| Tetragon | ... | ... |
| Wazuh | ... | ... |
| Suricata | ... | ... |
| Zeek | ... | ... |
| MISP | ... | ... |

### Critical Findings (MUST FIX)
[List]

### High Findings (SHOULD FIX)
[List]

### Medium Findings (CONSIDER)
[List]

### Recommendations
[Prioritized action items]
```

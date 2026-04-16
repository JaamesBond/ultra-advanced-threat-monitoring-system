---
name: k8s-review
description: Review Kubernetes manifests for security compliance, resource limits, privilege escalation risks, and XDR stack compatibility
---

# K8s Manifest Review — Big Chemistry XDR

Review Kubernetes manifests (YAML) for security compliance, best practices, and compatibility with the XDR security stack.

## Procedure

### Step 1: Identify Manifests

Find changed or target K8s manifests:
- `new-infra/k8s/wazuh/` — SIEM stack
- `new-infra/k8s/suricata/` — IDS/IPS
- `new-infra/k8s/zeek/` — Network analysis
- `new-infra/k8s/misp/` — Threat intel

Or check git diff: `git diff -- 'new-infra/k8s/**/*.yaml' 'new-infra/k8s/**/*.yml'`

### Step 2: Security Checks (BLOCKERS)

| # | Check | What to Look For |
|---|-------|-----------------|
| 1 | No privileged containers | `securityContext.privileged: true` only for IDS (Suricata/Zeek) |
| 2 | Drop all capabilities | `drop: ["ALL"]` then add back only needed ones |
| 3 | Read-only root filesystem | `readOnlyRootFilesystem: true` where possible |
| 4 | Non-root user | `runAsNonRoot: true` where possible |
| 5 | No hostPID/hostIPC | Unless explicitly required (Falco needs hostPID) |
| 6 | hostNetwork justified | Only Suricata/Zeek (packet capture) and Wazuh Agent |
| 7 | No wildcard RBAC | `rules[].resources: ["*"]` or `verbs: ["*"]` = flag |
| 8 | Secret references valid | ExternalSecret `secretStoreRef` + `key` match AWS Secrets Manager |

### Step 3: Resource Management

| Check | Standard |
|-------|----------|
| CPU/Memory requests set | Every container must have `resources.requests` |
| CPU/Memory limits set | Every container must have `resources.limits` |
| bc-prd pod budget | Total pod requests must fit 2x t3.medium (4GB RAM, 4 vCPU total) |
| bc-ctrl pod budget | Total pod requests must fit 2-3x t3.xlarge (32-48GB RAM, 8-12 vCPU total) |
| PVC size appropriate | Don't over-allocate EBS (costs $0.088/GB/month) |
| No unbounded replicas | HPA max must be set if using autoscaling |

### Step 4: Networking

| Check | Details |
|-------|---------|
| Service type | Internal services = ClusterIP. Cross-VPC = LoadBalancer with NLB annotations |
| NLB annotations | `service.beta.kubernetes.io/aws-load-balancer-scheme: internal` |
| Port conflicts | hostNetwork pods: verify ports don't conflict with other DaemonSets |
| DNS references | Cross-VPC: use `wazuh-manager.bc-ctrl.internal` (Route53 private zone) |

### Step 5: Operational

| Check | Details |
|-------|---------|
| Liveness/readiness probes | Must exist for Deployments/StatefulSets |
| Restart policy | DaemonSets = Always |
| Update strategy | StatefulSets: RollingUpdate with partition |
| Pod disruption budget | Production workloads should have PDB |
| Labels/annotations | Consistent labeling for Cilium NetworkPolicy selectors |
| Namespace | Workloads in correct namespace (wazuh, suricata, zeek, misp) |

### Step 6: XDR Compatibility

| Check | Details |
|-------|---------|
| Cilium compatible | No NodePort services unless justified (Cilium eBPF handles them differently) |
| Falco can observe | No seccomp profiles blocking Falco's eBPF syscall monitoring |
| Tetragon can enforce | TracingPolicy selectors match workload labels |
| Wazuh Agent coverage | DaemonSet runs on all nodes (no nodeSelector excluding nodes) |

### Step 7: Report

```
## K8s Review: [manifests reviewed]

### Security: [PASS / BLOCK]
[List violations]

### Resources: [PASS / WARN]
[List concerns]

### Networking: [PASS / WARN]
[List issues]

### XDR Compatibility: [PASS / WARN]
[List conflicts]

### Verdict: [APPROVE / NEEDS CHANGES]
[Required actions]
```

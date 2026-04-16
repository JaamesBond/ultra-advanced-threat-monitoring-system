---
name: incident-response
description: Guided incident investigation and response using the XDR security stack — Falco, Tetragon, Wazuh, Suricata, Zeek, Cilium
---

# Incident Response — Big Chemistry XDR

Guide the operator through security incident investigation using the full XDR stack. This skill provides structured investigation procedures and tool-specific commands.

## Procedure

### Step 1: Triage

Determine incident type from initial report:

| Type | Primary Tool | Secondary |
|------|-------------|-----------|
| Runtime anomaly (unexpected process, file access) | Falco | Tetragon, Wazuh |
| Network intrusion (C2, lateral movement) | Suricata | Zeek, Cilium |
| Privilege escalation (container breakout) | Tetragon | Falco, Wazuh |
| Data exfiltration | Zeek | Suricata, Cilium |
| Configuration tampering | Wazuh | Falco |
| Brute force / credential abuse | Wazuh | Suricata |
| Malware execution | Falco | Tetragon (SIGKILL), Wazuh |

### Step 2: Collect Evidence

Provide the operator with commands for each relevant tool:

**Falco — Runtime Events:**
```bash
# Recent alerts (bc-prd)
kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco --since=1h | jq '.'

# Filter by priority
kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco --since=1h | jq 'select(.priority == "Critical" or .priority == "Error")'

# Filter by rule name
kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco --since=1h | jq 'select(.rule == "Terminal shell in container")'
```

**Tetragon — Process/File/Network Events:**
```bash
# All enforcement events (SIGKILL)
kubectl -n kube-system logs ds/tetragon -c export-stdout --since=1h | jq 'select(.process_tracepoint.action == "SIGKILL")'

# Process execution events
kubectl -n kube-system logs ds/tetragon -c export-stdout --since=1h | jq 'select(.process_exec != null)'

# Network connections
kubectl -n kube-system logs ds/tetragon -c export-stdout --since=1h | jq 'select(.process_connect != null)'
```

**Wazuh — SIEM Correlation:**
```bash
# Manager logs (bc-ctrl)
kubectl -n wazuh logs statefulset/wazuh-manager --since=1h

# Agent status (bc-prd)
kubectl -n wazuh logs ds/wazuh-agent --since=1h

# Query Wazuh API (via manager pod)
kubectl -n wazuh exec statefulset/wazuh-manager -- curl -s -k -u admin:admin https://localhost:55000/security/events?limit=10
```

**Suricata — IDS Alerts:**
```bash
# EVE JSON alerts (bc-prd)
kubectl -n suricata logs ds/suricata --since=1h | jq 'select(.event_type == "alert")'

# Specific signature
kubectl -n suricata logs ds/suricata --since=1h | jq 'select(.alert.signature_id == XXXX)'
```

**Zeek — Network Metadata:**
```bash
# Connection logs
kubectl -n zeek logs ds/zeek --since=1h | grep "conn.log"

# DNS queries
kubectl -n zeek logs ds/zeek --since=1h | grep "dns.log"

# HTTP requests
kubectl -n zeek logs ds/zeek --since=1h | grep "http.log"
```

**Cilium — Network Policy Drops:**
```bash
# Policy verdict drops
kubectl -n kube-system exec ds/cilium -- cilium monitor --type drop --since=1h

# Hubble flow logs (if Hubble enabled)
kubectl -n kube-system exec ds/cilium -- hubble observe --since=1h --verdict DROPPED
```

### Step 3: Correlate

Cross-reference findings:
1. **Timeline**: Align events across tools by timestamp
2. **Source/Dest**: Match source IPs/pods across Suricata alerts, Zeek conn.log, Cilium drops
3. **Process chain**: Falco process tree + Tetragon process_exec → full attack chain
4. **Network path**: Zeek connections + Suricata alerts → external C2 or lateral movement

### Step 4: Contain

Recommend containment actions based on findings:

**Network isolation (immediate):**
```yaml
# CiliumNetworkPolicy — isolate compromised pod
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: quarantine-<pod-name>
spec:
  endpointSelector:
    matchLabels:
      app: <compromised-app>
  ingress: []  # deny all
  egress: []   # deny all
```

**Process kill (immediate):**
```yaml
# Tetragon TracingPolicy — kill specific process
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: kill-<malicious-process>
spec:
  kprobes:
    - call: sys_execve
      args:
        - index: 0
          type: string
      selectors:
        - matchArgs:
            - index: 0
              operator: Equal
              values:
                - /path/to/malicious/binary
          matchActions:
            - action: Sigkill
```

**Pod deletion (if compromised):**
```bash
kubectl delete pod <compromised-pod> -n <namespace> --grace-period=0 --force
```

### Step 5: Document

Output incident report:

```
## Incident Report

### Summary
[One-line description]

### Timeline
| Time | Source | Event |
|------|--------|-------|

### Affected Resources
[Pods, nodes, namespaces, VPCs]

### Root Cause
[Analysis]

### Actions Taken
[Containment + remediation steps]

### Recommendations
[Prevent recurrence]

### Evidence Artifacts
[Log excerpts, screenshots, policy changes]
```

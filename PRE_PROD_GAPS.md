# Pre-Production Security Gaps

This document tracks **known, accepted gaps** in the current UATMS implementation.
Every item here is a conscious deferral — not an oversight.

**None of these are acceptable in a production deployment.**
Before declaring prod-ready, each gap must be resolved or formally risk-accepted by a stakeholder.

---

## GAP-001: Wazuh Agent → Manager Traffic Unencrypted

**Component**: wazuh-agent DaemonSet (bc-prd) → Wazuh Manager EC2 (bc-ctrl)
**Severity**: High
**Traffic path**: TCP 1514 across VPC peering — unencrypted at the application layer

VPC peering does not encrypt traffic in transit. A compromised node in either VPC can intercept raw telemetry — the very alerts meant to detect a breach. An attacker who reads this stream is informed while you remain blind.

**Fix**: Enable Wazuh `secure` mode on the manager. Create a self-signed CA on the Wazuh EC2 using OpenSSL (zero cost). Sign server cert for manager, client certs for agents. Distribute CA cert to agent pods via Kubernetes Secret. Configure `<connection>secure</connection>` in `ossec.conf`.

**Cost of fix**: Zero (self-signed CA, no AWS Private CA needed).

---

## GAP-002: MISP TLS Not Validated (curl -k)

**Component**: Suricata `misp-rule-sync` sidecar, Zeek `misp-intel-sync` sidecar
**Severity**: High
**Location**: Sidecar container entrypoint scripts

Both sidecars connect to `misp.bc-ctrl.internal` using `curl -k` — certificate validation disabled. A Man-in-the-Middle attacker who can intercept traffic between bc-prd and bc-ctrl could serve a fake MISP response, injecting false IOCs into Zeek or bogus rules into Suricata. This can blind your IDS or create detection noise.

**Fix**: Create a self-signed CA on MISP EC2. Sign MISP's server cert. Mount the CA cert into sidecar containers via Kubernetes Secret. Remove `-k` from all curl calls and replace with `--cacert /etc/ssl/misp-ca.crt`.

**Cost of fix**: Zero.

---

## GAP-003: Container Image Supply Chain Not Verified

**Component**: All DaemonSet and Helm-deployed images
**Severity**: High
**Affected images**:
- `zeek/zeek:7.0.5` (public Docker Hub)
- `jasonish/suricata:7.0.7` (public Docker Hub)
- `286439316079.dkr.ecr.eu-central-1.amazonaws.com/wazuh-agent:4.9.0` (ECR — internal)
- All Cilium, Falco, Tetragon Helm chart images

No image signing or admission controller verifies image integrity before scheduling. A compromised upstream image (typosquatting, registry compromise, tag mutation) would run without challenge.

**Fix**: Implement Cosign image signing for ECR-hosted images. Deploy a Kubernetes admission controller (Kyverno or OPA Gatekeeper) with a policy requiring signed images. For public images: pin to SHA256 digest instead of mutable tags.

Example — replace:
```yaml
image: zeek/zeek:7.0.5
```
With:
```yaml
image: zeek/zeek@sha256:<exact-digest>
```

**Cost of fix**: Low — Kyverno is free, digest pinning is a one-line change.

---

## GAP-004: Wazuh All-in-One is a Single Point of Failure

**Component**: Wazuh Manager EC2 (`t3.xlarge`, bc-ctrl)
**Severity**: Medium
**Impact**: Full XDR telemetry pipeline goes dark if instance fails

Manager, OpenSearch Indexer, and Dashboard run on one EC2 instance. If it fails, wazuh-agent pods buffer events in memory until the buffer fills, then **drop events permanently**. No alerts reach the dashboard during the outage window.

**Fix**: Wazuh distributed deployment — separate EC2s for Manager, Indexer (OpenSearch cluster, minimum 3 nodes), and Dashboard. Alternatively: Wazuh Cloud or a managed OpenSearch domain for the indexer layer.

**Cost of fix**: Significant — adds 2-3 EC2 instances. Requires budget approval against $565/month ceiling.

---

## GAP-005: Splunk SOAR Running but Idle, Over-Privileged, and Unwired (reconciled 2026-06-10)

**Component**: `splunk-soar-ec2` (t3.xlarge, Amazon Linux 2023, bc-ctrl private subnet) — **replaces the old "Shuffle EC2" framing**
**Severity**: Medium
**Impact**: A standing, undocumented, over-privileged SOAR box that performs no detection/response work

Reconciliation of the previous "Shuffle has no SSM profile" gap against the live account (Op-4 control-plane red-team, 2026-06-10):

- **It is running and TF-managed.** `splunksoar.tf` resources are applied (not commented out). The box runs **Splunk SOAR 8.5.0.248** (unprivileged install), UI on `nginx:8443` (returns HTTP 302 login redirect), PostgreSQL 15 + pgbouncer + RabbitMQ backend. It **is** SSM-managed (`AmazonSSMManagedInstanceCore`), so the old "no SSM" concern is resolved.
- **It IS wired to Wazuh but does nothing with the data.** SOAR has ingested **929 alert containers, every one `label=wazuh_alert`** (newest the same day) — so the `custom-splunk-soar.py` integration is delivering despite a stale "replace me" comment on its `hook_url`. Wazuh feeds **both** Shuffle (via the `shuffle` integration in `integratord`) **and** Splunk SOAR. But SOAR is a **passive sink**: **0 response assets, 0 active playbooks, 0 `playbook_run`, 0 `app_run` ever** — it has never executed a single automated action. This is GAP-006 made concrete on the box meant to provide response. (Earlier triage said "0 containers / not wired"; that was a bad combined SQL query — corrected here.)
- **Admin console opens with default/weak credentials** (`soar_local_admin`). The authenticated dashboard exposes the full 929-event Wazuh feed (a live map of what the defenders see) plus admin control of the over-privileged box. Network isolation (no inbound SG, SSM-only) is the only thing keeping that console off the network.
- **It is over-privileged.** The instance role `splunk-soar-ec2-role` carries `lambda:InvokeFunction` + `lambda:InvokeAsync` on `Resource: "*"` (24 functions account-wide, including the destructive IR Lambdas `nukeIAMPerms` / `quarantineEC2` / `removeEC2FromEKS`). See **finding F-14** — a SOAR-box compromise weaponizes the IR automation. Network isolation is a genuine strength: the SOAR SG has **no inbound rules** (SSM-only; unreachable from bc-prd or the internet).

**Fix**: (1) **Change the default `soar_local_admin` password** immediately. (2) Decide Shuffle **or** Splunk SOAR as the single SOAR and remove the duplicate forwarding; if keeping Splunk SOAR, configure at least one asset + active playbook so the 929 ingested alerts actually drive a response (closes GAP-006). (3) Scope `splunk-soar-ec2-role` down from `lambda:Invoke *` to only the specific IR function ARNs it must call. (4) If the box is not in active use, stop/right-size it (t3.xlarge is the most expensive standing instance in bc-ctrl).

**Cost of fix**: Zero for the IAM/wiring changes; **saves** money if the idle t3.xlarge is stopped.

---

## GAP-006: No Wazuh Active Response Configured

**Component**: Wazuh Manager + wazuh-agent
**Severity**: Medium
**Impact**: Detection without enforcement — alerts fire but no automated response occurs

Wazuh detects threats (container escapes, brute force, privilege escalation) but takes no automated action. The pipeline is passive — it informs, it does not respond.

**Fix**: Configure Wazuh active response scripts on the manager. Examples:
- Block source IP via `iptables` on brute-force detection
- Kill offending process on container escape detection
- Trigger Shuffle SOAR workflow for high-severity alerts

**Cost of fix**: Zero — configuration only.

---

## GAP-007: No Certificate Rotation Plan

**Component**: All TLS certificates across the stack (once GAP-001 and GAP-002 are fixed)
**Severity**: Medium
**Impact**: Certificates will expire, silently breaking the pipeline

Once TLS is enabled for Wazuh and MISP, certificates will have expiry dates. There is currently no rotation mechanism — no cert-manager, no automated renewal, no alerting on expiry.

**Fix**: Deploy `cert-manager` in bc-prd EKS for pod-facing certificates. For EC2-hosted certs (Wazuh, MISP): cron job on the EC2 to renew and reload. Alert on cert expiry in Wazuh rules (< 30 days remaining).

**Cost of fix**: Zero (cert-manager is free).

---

## GAP-008: No OpenSearch Log Archiving to S3

**Component**: Wazuh Manager EC2 — OpenSearch Indexer
**Severity**: Medium
**Impact**: No durable long-term log archive — data loss on EC2 failure, no compliance-grade retention

OpenSearch holds telemetry indices on local EBS only. There is no snapshot repository configured. If the Wazuh EC2 fails and is rebuilt, all historical alert data is permanently lost. Hot indices also grow unbounded, eventually exhausting disk and crashing OpenSearch.

This is a **cold path** concern — separate from the active hostPath → wazuh-agent → OpenSearch pipeline. The hot path is fine. The archive path does not exist.

**Fix**: Configure an OpenSearch snapshot repository pointing to an S3 bucket. Schedule automated snapshots (daily minimum, hourly for tighter RPO):

```bash
# Register S3 snapshot repository
curl -X PUT "https://localhost:9200/_snapshot/s3_archive" \
  -H "Content-Type: application/json" -d '{
    "type": "s3",
    "settings": {
      "bucket": "bc-uatms-wazuh-snapshots",
      "region": "eu-central-1",
      "base_path": "opensearch-snapshots"
    }
  }'

# Schedule daily snapshot via cron on the EC2
0 2 * * * curl -X PUT "https://localhost:9200/_snapshot/s3_archive/snapshot-$(date +%F)"
```

For compliance: enable **S3 Object Lock** (WORM) on the snapshot bucket to make archives immutable.

**What this does NOT fix**: GAP-004 (Wazuh SPOF). Snapshots enable DR recovery, not live HA failover.

**Cost of fix**: S3 storage cost only — roughly $2-5/month depending on index size and retention period. Wazuh EC2 already has an IAM role with S3 access to `bc-uatms-wazuh-snapshots`.

---

## Gap Resolution Checklist

Before declaring prod-ready, verify each item:

| Gap | Severity | Resolved | Resolved By | Date |
|-----|----------|----------|-------------|------|
| GAP-001: Wazuh TLS | High | [ ] | | |
| GAP-002: MISP curl -k | High | [ ] | | |
| GAP-003: Image supply chain | High | [ ] | | |
| GAP-004: Wazuh SPOF | Medium | [ ] | | |
| GAP-005: Splunk SOAR passive/over-priv/default-creds | Medium | [ ] | | Running+TF-managed; wired to Wazuh (929 events) but 0 playbooks/actions ever; default `soar_local_admin` creds; role has `lambda:Invoke *` (F-14) |
| GAP-006: No active response | Medium | [ ] | | |
| GAP-007: No cert rotation | Medium | [ ] | | |
| GAP-008: No OpenSearch S3 snapshots | Medium | [ ] | | |

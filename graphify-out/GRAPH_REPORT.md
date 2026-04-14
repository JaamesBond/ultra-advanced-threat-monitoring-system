# Graph Report - new-infra  (2026-04-14)

## Corpus Check
- Corpus is ~840 words - fits in a single context window. You may not need a graph.

## Summary
- 100 nodes · 132 edges · 13 communities detected
- Extraction: 96% EXTRACTED · 4% INFERRED · 0% AMBIGUOUS · INFERRED: 5 edges (avg confidence: 0.79)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Traffic Mirror Lifecycle|Traffic Mirror Lifecycle]]
- [[_COMMUNITY_XDR Data Pipeline|XDR Data Pipeline]]
- [[_COMMUNITY_Auto Mirror Lambda Functions|Auto Mirror Lambda Functions]]
- [[_COMMUNITY_Prevention & Supply Chain|Prevention & Supply Chain]]
- [[_COMMUNITY_eBPF Enforcement & Detection|eBPF Enforcement & Detection]]
- [[_COMMUNITY_AWS Native Monitoring|AWS Native Monitoring]]
- [[_COMMUNITY_VPC Network Segmentation|VPC Network Segmentation]]
- [[_COMMUNITY_DDoS & Traffic Gaps|DDoS & Traffic Gaps]]
- [[_COMMUNITY_Deployment Guide|Deployment Guide]]
- [[_COMMUNITY_Threat Intel & AI|Threat Intel & AI]]
- [[_COMMUNITY_Phishing Gap|Phishing Gap]]
- [[_COMMUNITY_Deception Gap|Deception Gap]]
- [[_COMMUNITY_UEBA Gap|UEBA Gap]]

## God Nodes (most connected - your core abstractions)
1. `XDR Pipeline (Collector -> MSK -> Flink -> ML -> Verdict)` - 16 edges
2. `Tetragon (eBPF In-Kernel Enforcer, Layer 1)` - 9 edges
3. `Multi-VPC Network Segmentation` - 8 edges
4. `Seven Sensor Detection Layers` - 8 edges
5. `AWS GuardDuty (ML Threat Detection, Layer 6)` - 7 edges
6. `delete_session()` - 6 edges
7. `XDR Security Architecture (AWS Cloud Deployment)` - 6 edges
8. `Wazuh HIDS (Host Intrusion Detection, Layer 3)` - 6 edges
9. `Cilium CNI + eBPF (East-West, Layer 4)` - 6 edges
10. `Suricata NIDS (Network Layer 5, VPC Traffic Mirroring)` - 6 edges

## Surprising Connections (you probably didn't know these)
- `XDR Security Architecture (AWS Cloud Deployment)` --references--> `Seven Sensor Detection Layers`  [EXTRACTED]
  new-infra/docs/xdr-aws-explained.pdf → new-infra/docs/xdr-aws-explained.pdf  _Bridges community 3 → community 4_
- `XDR Security Architecture (AWS Cloud Deployment)` --references--> `Multi-VPC Network Segmentation`  [EXTRACTED]
  new-infra/docs/xdr-aws-explained.pdf → new-infra/docs/xdr-aws-explained.pdf  _Bridges community 3 → community 6_
- `XDR Security Architecture (AWS Cloud Deployment)` --references--> `XDR Pipeline (Collector -> MSK -> Flink -> ML -> Verdict)`  [EXTRACTED]
  new-infra/docs/xdr-aws-explained.pdf → new-infra/docs/xdr-aws-explained.pdf  _Bridges community 3 → community 1_
- `Multi-VPC Network Segmentation` --references--> `AWS Shield Advanced (DDoS Protection)`  [EXTRACTED]
  new-infra/docs/xdr-aws-explained.pdf → new-infra/docs/xdr-aws-explained.pdf  _Bridges community 6 → community 7_
- `Seven Sensor Detection Layers` --references--> `Wazuh HIDS (Host Intrusion Detection, Layer 3)`  [EXTRACTED]
  new-infra/docs/xdr-aws-explained.pdf → new-infra/docs/xdr-aws-explained.pdf  _Bridges community 4 → community 5_

## Hyperedges (group relationships)
- **Seven Sensors Feed XDR Pipeline for Unified Verdict** — pdf_tetragon, pdf_falco, pdf_wazuh, pdf_cilium, pdf_suricata, pdf_guardduty, pdf_dns_monitoring, pdf_xdr_pipeline [EXTRACTED 1.00]
- **Tier 0/1/2 Defense Tiers Form Independent Layered Protection** — pdf_tier0_prevention, pdf_tier1_autonomous, pdf_tier2_soar, pdf_tiered_defense, pdf_enforcement_api [EXTRACTED 1.00]
- **Traffic Mirror Lifecycle Flow** — eventbridge_asg_lifecycle, handler, create_session, delete_session, vpc_traffic_mirroring [INFERRED]
- **Suricata Inspection Pipeline** — bc_prd_eks, auto_mirror_lambda, mirror_filter, mirror_target_nlb, suricata_nids [INFERRED]
- **Idempotent Session Management Pattern** — create_session, find_session_for_eni, _delete [INFERRED]

## Communities

### Community 0 - "Traffic Mirror Lifecycle"
Cohesion: 0.18
Nodes (15): _delete(), auto_mirror Lambda, bc-prd EKS Cluster, create_session(), delete_session(), EventBridge ASG Lifecycle Events, find_session_for_eni(), get_primary_eni() (+7 more)

### Community 1 - "XDR Data Pipeline"
Cohesion: 0.15
Nodes (14): Collector (nProbe + Vector, ECS Normalisation), DNS Monitoring + Identity/Auth Logs (Layer 7), XDR Fast Path (>95% Confidence, Skip AI, ~1.5-2s), Hubble (Pod Flow Observability), Amazon Managed Flink (CEP + Stream Processing), ML Tier 1: LightGBM (Fast, All Events), ML Tier 2: CNN + GNN + Autoencoder (Deep, ~5% Events), Amazon MSK (Managed Kafka, Event Buffer) (+6 more)

### Community 2 - "Auto Mirror Lambda Functions"
Cohesion: 0.26
Nodes (12): create_session(), _delete(), delete_session(), find_session_for_eni(), get_primary_eni(), handler(), is_eks_node(), auto_mirror.py — Dynamic VPC Traffic Mirror Session manager  Triggered by EventB (+4 more)

### Community 3 - "Prevention & Supply Chain"
Cohesion: 0.18
Nodes (11): EKS (Elastic Kubernetes Service), Gap: Supply Chain Response (No Post-Deploy SOAR Playbook), Kyverno (Policy Engine, Admission Controller), Rationale: Managed Services Trade OPEX for Zero Operational Overhead, Sigstore (Container Image Signing), Tier 0: Prevention (Always-On, Zero Latency), Tier 1: Autonomous Response (<1ms to 50ms), Tier 2: SOAR-Orchestrated Response (1-5s) (+3 more)

### Community 4 - "eBPF Enforcement & Detection"
Cohesion: 0.31
Nodes (11): Cilium CNI + eBPF (East-West, Layer 4), DFIR-IRIS (Case Management + ML Feedback), Falco (Container Runtime Security, Layer 2), Gap: No Explicit EDR Capability, Gap: ML Retraining Pipeline Not Shown, Rationale: Tetragon Tier-1 Autonomy (Zero SOAR/Kafka Dependency), Attack Scenario: Container Compromise, Attack Scenario: Lateral Movement (Zone B to Zone A) (+3 more)

### Community 5 - "AWS Native Monitoring"
Cohesion: 0.2
Nodes (10): AWS CloudTrail (API Audit Logging), Gap: GuardDuty Latency (1-5 min), AWS GuardDuty (ML Threat Detection, Layer 6), AWS Inspector (Vulnerability Scanning), AWS Macie (Sensitive Data Detection), Attack Scenario: Brute Force + Credential Abuse, AWS Security Hub (Findings Aggregator), Wazuh HIDS (Host Intrusion Detection, Layer 3) (+2 more)

### Community 6 - "VPC Network Segmentation"
Cohesion: 0.25
Nodes (9): AWS Transit Gateway (Inter-VPC Router), AWS WAF (Web Application Firewall), Enforcement API (FastAPI + Celery, boto3 Workers), Multi-VPC Network Segmentation, Network ACLs (Stateless Subnet Filters), Production VPC Zone A, Rationale: AWS VPC as SDN (No Separate Controller), Research VPC Zone B (+1 more)

### Community 7 - "DDoS & Traffic Gaps"
Cohesion: 0.33
Nodes (6): Gap: No Encrypted Traffic Inspection, Gap: VPC Flow Log Delay (1-10 min), Gap: VPC Traffic Mirroring Bandwidth Cap and Cost, Attack Scenario: DDoS Attack, AWS Shield Advanced (DDoS Protection), Suricata NIDS (Network Layer 5, VPC Traffic Mirroring)

### Community 8 - "Deployment Guide"
Cohesion: 0.5
Nodes (5): Guide: Control Plane VPC Deploy Step, Guide: Steps 3+4 Parallel After Step 2, Guide: Production VPC Deploy Step, Guide: Transit Gateway Deploy Step, Guide: XDR VPC Deploy Step

### Community 9 - "Threat Intel & AI"
Cohesion: 0.67
Nodes (3): Amazon Bedrock AI Investigation (Claude, RAG + ATT&CK), MISP + OpenCTI (Threat Intelligence / CTI), MITRE ATT&CK Framework

### Community 10 - "Phishing Gap"
Cohesion: 1.0
Nodes (1): Gap: No Email/Phishing Detection (MITRE T1566)

### Community 11 - "Deception Gap"
Cohesion: 1.0
Nodes (1): Gap: No Deception Layer (No Honeypots/Honeytokens)

### Community 12 - "UEBA Gap"
Cohesion: 1.0
Nodes (1): Gap: No UEBA (No User Entity Behaviour Analytics)

## Knowledge Gaps
- **36 isolated node(s):** `auto_mirror.py — Dynamic VPC Traffic Mirror Session manager  Triggered by EventB`, `Return True if the instance belongs to EKS_CLUSTER_NAME.`, `Return the primary ENI ID (device-index 0) for the instance.     Retries because`, `Return the TrafficMirrorSessionId for the given ENI, if any.`, `Delete the mirror session for the terminating instance.     The ENI may already` (+31 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **Thin community `Phishing Gap`** (1 nodes): `Gap: No Email/Phishing Detection (MITRE T1566)`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Deception Gap`** (1 nodes): `Gap: No Deception Layer (No Honeypots/Honeytokens)`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `UEBA Gap`** (1 nodes): `Gap: No UEBA (No User Entity Behaviour Analytics)`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `XDR Pipeline (Collector -> MSK -> Flink -> ML -> Verdict)` connect `XDR Data Pipeline` to `Prevention & Supply Chain`, `eBPF Enforcement & Detection`, `AWS Native Monitoring`, `DDoS & Traffic Gaps`?**
  _High betweenness centrality (0.188) - this node is a cross-community bridge._
- **Why does `XDR Security Architecture (AWS Cloud Deployment)` connect `Prevention & Supply Chain` to `XDR Data Pipeline`, `eBPF Enforcement & Detection`, `VPC Network Segmentation`?**
  _High betweenness centrality (0.091) - this node is a cross-community bridge._
- **Why does `AWS GuardDuty (ML Threat Detection, Layer 6)` connect `AWS Native Monitoring` to `XDR Data Pipeline`, `eBPF Enforcement & Detection`, `DDoS & Traffic Gaps`?**
  _High betweenness centrality (0.068) - this node is a cross-community bridge._
- **Are the 3 inferred relationships involving `Tetragon (eBPF In-Kernel Enforcer, Layer 1)` (e.g. with `Falco (Container Runtime Security, Layer 2)` and `Cilium CNI + eBPF (East-West, Layer 4)`) actually correct?**
  _`Tetragon (eBPF In-Kernel Enforcer, Layer 1)` has 3 INFERRED edges - model-reasoned connections that need verification._
- **What connects `auto_mirror.py — Dynamic VPC Traffic Mirror Session manager  Triggered by EventB`, `Return True if the instance belongs to EKS_CLUSTER_NAME.`, `Return the primary ENI ID (device-index 0) for the instance.     Retries because` to the rest of the system?**
  _36 weakly-connected nodes found - possible documentation gaps or missing edges._
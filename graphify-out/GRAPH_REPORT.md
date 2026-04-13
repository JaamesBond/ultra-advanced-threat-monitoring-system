# Graph Report - .  (2026-04-13)

## Corpus Check
- Corpus is ~2,003 words - fits in a single context window. You may not need a graph.

## Summary
- 93 nodes · 124 edges · 15 communities detected
- Extraction: 90% EXTRACTED · 10% INFERRED · 0% AMBIGUOUS · INFERRED: 12 edges (avg confidence: 0.84)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Terraform Infrastructure & Deploy|Terraform Infrastructure & Deploy]]
- [[_COMMUNITY_XDR Data Pipeline & ML|XDR Data Pipeline & ML]]
- [[_COMMUNITY_Network Segmentation & Enforcement|Network Segmentation & Enforcement]]
- [[_COMMUNITY_AWS Security Services & HIDS|AWS Security Services & HIDS]]
- [[_COMMUNITY_Container & eBPF Sensors|Container & eBPF Sensors]]
- [[_COMMUNITY_Supply Chain & Prevention|Supply Chain & Prevention]]
- [[_COMMUNITY_Network IPS & Gaps|Network IPS & Gaps]]
- [[_COMMUNITY_Deployment Guide VPCs|Deployment Guide VPCs]]
- [[_COMMUNITY_Threat Intelligence & AI|Threat Intelligence & AI]]
- [[_COMMUNITY_VPC Terraform Modules|VPC Terraform Modules]]
- [[_COMMUNITY_TGW Module|TGW Module]]
- [[_COMMUNITY_Phishing Gap|Phishing Gap]]
- [[_COMMUNITY_Deception Gap|Deception Gap]]
- [[_COMMUNITY_UEBA Gap|UEBA Gap]]
- [[_COMMUNITY_Graph Meta|Graph Meta]]

## God Nodes (most connected - your core abstractions)
1. `XDR Pipeline (Collector -> MSK -> Flink -> ML -> Verdict)` - 16 edges
2. `XDR VPC (bc-xdr, 10.11.0.0/16)` - 10 edges
3. `Multi-VPC Network Segmentation` - 9 edges
4. `Tetragon (eBPF In-Kernel Enforcer, Layer 1)` - 9 edges
5. `Seven Sensor Detection Layers` - 8 edges
6. `Terraform Deployment Order (TGW -> XDR -> Ctrl || Prd)` - 7 edges
7. `AWS GuardDuty (ML Threat Detection, Layer 6)` - 7 edges
8. `Transit Gateway (Shared)` - 6 edges
9. `XDR Security Architecture (AWS Cloud Deployment)` - 6 edges
10. `Wazuh HIDS (Host Intrusion Detection, Layer 3)` - 6 edges

## Surprising Connections (you probably didn't know these)
- `Transit Gateway (Shared)` --semantically_similar_to--> `AWS Transit Gateway (Inter-VPC Router)`  [INFERRED] [semantically similar]
  CLAUDE.md → new-infra/docs/xdr-aws-explained.pdf
- `XDR VPC (bc-xdr, 10.11.0.0/16)` --semantically_similar_to--> `Multi-VPC Network Segmentation`  [INFERRED] [semantically similar]
  CLAUDE.md → new-infra/docs/xdr-aws-explained.pdf
- `Production VPC (bc-prd, 10.30.0.0/16)` --semantically_similar_to--> `Production VPC Zone A`  [INFERRED] [semantically similar]
  CLAUDE.md → new-infra/docs/xdr-aws-explained.pdf
- `EKS Node Group: collector (m6a.large)` --semantically_similar_to--> `Collector (nProbe + Vector, ECS Normalisation)`  [INFERRED] [semantically similar]
  CLAUDE.md → new-infra/docs/xdr-aws-explained.pdf
- `EKS Node Group: ml (g4dn SPOT, GPU taint)` --semantically_similar_to--> `Triton on EKS (ML Model Serving, Spot GPU)`  [INFERRED] [semantically similar]
  CLAUDE.md → new-infra/docs/xdr-aws-explained.pdf

## Hyperedges (group relationships)
- **Seven Sensors Feed XDR Pipeline for Unified Verdict** — pdf_tetragon, pdf_falco, pdf_wazuh, pdf_cilium, pdf_suricata, pdf_guardduty, pdf_dns_monitoring, pdf_xdr_pipeline [EXTRACTED 1.00]
- **Tier 0/1/2 Defense Tiers Form Independent Layered Protection** — pdf_tier0_prevention, pdf_tier1_autonomous, pdf_tier2_soar, pdf_tiered_defense, pdf_enforcement_api [EXTRACTED 1.00]
- **Terraform Deployment Ordering: TGW -> XDR VPC -> Ctrl + Prd VPCs** — claude_md_transit_gateway, claude_md_xdr_vpc, claude_md_ctrl_vpc, claude_md_prd_vpc, claude_md_deploy_order, claude_md_ci_deploy [EXTRACTED 1.00]

## Communities

### Community 0 - "Terraform Infrastructure & Deploy"
Cohesion: 0.17
Nodes (17): TGW Appliance Mode (enable) on XDR Attachment, CI Workflow: terraform-deploy.yml (Push to Main), CI Workflow: terraform-plan.yml (PR), EKS Node Group: collector (m6a.large), EKS Node Group: cti (m6a.xlarge, dedicated taint), Control Plane VPC (bc-ctrl, 10.0.0.0/16), Terraform Deployment Order (TGW -> XDR -> Ctrl || Prd), EC2 Test Instance Workaround (SCP blocks eks:CreateCluster) (+9 more)

### Community 1 - "XDR Data Pipeline & ML"
Cohesion: 0.15
Nodes (14): Collector (nProbe + Vector, ECS Normalisation), DNS Monitoring + Identity/Auth Logs (Layer 7), XDR Fast Path (>95% Confidence, Skip AI, ~1.5-2s), Hubble (Pod Flow Observability), Amazon Managed Flink (CEP + Stream Processing), ML Tier 1: LightGBM (Fast, All Events), ML Tier 2: CNN + GNN + Autoencoder (Deep, ~5% Events), Amazon MSK (Managed Kafka, Event Buffer) (+6 more)

### Community 2 - "Network Segmentation & Enforcement"
Cohesion: 0.22
Nodes (11): AWS Transit Gateway (Inter-VPC Router), AWS WAF (Web Application Firewall), Enforcement API (FastAPI + Celery, boto3 Workers), Multi-VPC Network Segmentation, Network ACLs (Stateless Subnet Filters), Production VPC Zone A, Rationale: AWS VPC as SDN (No Separate Controller), Research VPC Zone B (+3 more)

### Community 3 - "AWS Security Services & HIDS"
Cohesion: 0.18
Nodes (11): AWS CloudTrail (API Audit Logging), Gap: GuardDuty Latency (1-5 min), AWS GuardDuty (ML Threat Detection, Layer 6), AWS Inspector (Vulnerability Scanning), AWS Macie (Sensitive Data Detection), Attack Scenario: Brute Force + Credential Abuse, AWS Security Hub (Findings Aggregator), Tier 1: Autonomous Response (<1ms to 50ms) (+3 more)

### Community 4 - "Container & eBPF Sensors"
Cohesion: 0.33
Nodes (10): Cilium CNI + eBPF (East-West, Layer 4), DFIR-IRIS (Case Management + ML Feedback), Falco (Container Runtime Security, Layer 2), Gap: No Explicit EDR Capability, Gap: ML Retraining Pipeline Not Shown, Rationale: Tetragon Tier-1 Autonomy (Zero SOAR/Kafka Dependency), Attack Scenario: Container Compromise, Attack Scenario: Lateral Movement (Zone B to Zone A) (+2 more)

### Community 5 - "Supply Chain & Prevention"
Cohesion: 0.22
Nodes (9): EKS (Elastic Kubernetes Service), Gap: Supply Chain Response (No Post-Deploy SOAR Playbook), Kyverno (Policy Engine, Admission Controller), Rationale: Managed Services Trade OPEX for Zero Operational Overhead, Sigstore (Container Image Signing), Tier 0: Prevention (Always-On, Zero Latency), Tiered Defense Model (Tier 0/1/2), Trivy (Container Image Vulnerability Scanning) (+1 more)

### Community 6 - "Network IPS & Gaps"
Cohesion: 0.33
Nodes (6): Gap: No Encrypted Traffic Inspection, Gap: VPC Flow Log Delay (1-10 min), Gap: VPC Traffic Mirroring Bandwidth Cap and Cost, Attack Scenario: DDoS Attack, AWS Shield Advanced (DDoS Protection), Suricata NIDS (Network Layer 5, VPC Traffic Mirroring)

### Community 7 - "Deployment Guide VPCs"
Cohesion: 0.5
Nodes (5): Guide: Control Plane VPC Deploy Step, Guide: Steps 3+4 Parallel After Step 2, Guide: Production VPC Deploy Step, Guide: Transit Gateway Deploy Step, Guide: XDR VPC Deploy Step

### Community 8 - "Threat Intelligence & AI"
Cohesion: 0.67
Nodes (3): Amazon Bedrock AI Investigation (Claude, RAG + ATT&CK), MISP + OpenCTI (Threat Intelligence / CTI), MITRE ATT&CK Framework

### Community 9 - "VPC Terraform Modules"
Cohesion: 1.0
Nodes (2): VPC Interface Endpoints (S3, ECR, SSM, KMS), VPC Terraform Module (wraps terraform-aws-modules/vpc v6.5.1)

### Community 10 - "TGW Module"
Cohesion: 1.0
Nodes (1): TGW Terraform Module

### Community 11 - "Phishing Gap"
Cohesion: 1.0
Nodes (1): Gap: No Email/Phishing Detection (MITRE T1566)

### Community 12 - "Deception Gap"
Cohesion: 1.0
Nodes (1): Gap: No Deception Layer (No Honeypots/Honeytokens)

### Community 13 - "UEBA Gap"
Cohesion: 1.0
Nodes (1): Gap: No UEBA (No User Entity Behaviour Analytics)

### Community 14 - "Graph Meta"
Cohesion: 1.0
Nodes (1): Graph Report: 68 Nodes, 102 Edges, 10 Communities

## Knowledge Gaps
- **34 isolated node(s):** `Rationale: Appliance Mode Prevents Asymmetric Routing on IPS`, `EC2 Test Instance Workaround (SCP blocks eks:CreateCluster)`, `Terraform Remote State Wiring (S3 Backend)`, `VPC Terraform Module (wraps terraform-aws-modules/vpc v6.5.1)`, `TGW Terraform Module` (+29 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **Thin community `VPC Terraform Modules`** (2 nodes): `VPC Interface Endpoints (S3, ECR, SSM, KMS)`, `VPC Terraform Module (wraps terraform-aws-modules/vpc v6.5.1)`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `TGW Module`** (1 nodes): `TGW Terraform Module`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Phishing Gap`** (1 nodes): `Gap: No Email/Phishing Detection (MITRE T1566)`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Deception Gap`** (1 nodes): `Gap: No Deception Layer (No Honeypots/Honeytokens)`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `UEBA Gap`** (1 nodes): `Gap: No UEBA (No User Entity Behaviour Analytics)`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Graph Meta`** (1 nodes): `Graph Report: 68 Nodes, 102 Edges, 10 Communities`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `XDR Pipeline (Collector -> MSK -> Flink -> ML -> Verdict)` connect `XDR Data Pipeline & ML` to `Network Segmentation & Enforcement`, `AWS Security Services & HIDS`, `Container & eBPF Sensors`, `Supply Chain & Prevention`, `Network IPS & Gaps`?**
  _High betweenness centrality (0.360) - this node is a cross-community bridge._
- **Why does `Multi-VPC Network Segmentation` connect `Network Segmentation & Enforcement` to `Terraform Infrastructure & Deploy`, `Supply Chain & Prevention`, `Network IPS & Gaps`?**
  _High betweenness centrality (0.334) - this node is a cross-community bridge._
- **Why does `XDR VPC (bc-xdr, 10.11.0.0/16)` connect `Terraform Infrastructure & Deploy` to `Network Segmentation & Enforcement`?**
  _High betweenness centrality (0.326) - this node is a cross-community bridge._
- **Are the 3 inferred relationships involving `Tetragon (eBPF In-Kernel Enforcer, Layer 1)` (e.g. with `Falco (Container Runtime Security, Layer 2)` and `Cilium CNI + eBPF (East-West, Layer 4)`) actually correct?**
  _`Tetragon (eBPF In-Kernel Enforcer, Layer 1)` has 3 INFERRED edges - model-reasoned connections that need verification._
- **What connects `Rationale: Appliance Mode Prevents Asymmetric Routing on IPS`, `EC2 Test Instance Workaround (SCP blocks eks:CreateCluster)`, `Terraform Remote State Wiring (S3 Backend)` to the rest of the system?**
  _34 weakly-connected nodes found - possible documentation gaps or missing edges._
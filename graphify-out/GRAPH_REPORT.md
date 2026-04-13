# Graph Report - .  (2026-04-13)

## Corpus Check
- Corpus is ~5,597 words - fits in a single context window. You may not need a graph.

## Summary
- 68 nodes · 102 edges · 10 communities detected
- Extraction: 94% EXTRACTED · 6% INFERRED · 0% AMBIGUOUS · INFERRED: 6 edges (avg confidence: 0.78)
- Token cost: 9,800 input · 4,200 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Multi-VPC Network Architecture|Multi-VPC Network Architecture]]
- [[_COMMUNITY_AI-Powered Threat Intelligence|AI-Powered Threat Intelligence]]
- [[_COMMUNITY_AWS Native Security Services|AWS Native Security Services]]
- [[_COMMUNITY_Prevention and Policy Layer|Prevention and Policy Layer]]
- [[_COMMUNITY_Container and Network Security|Container and Network Security]]
- [[_COMMUNITY_Detection Pipeline and ML|Detection Pipeline and ML]]
- [[_COMMUNITY_DNS WAF and Enforcement|DNS WAF and Enforcement]]
- [[_COMMUNITY_Gap Encrypted Traffic|Gap: Encrypted Traffic]]
- [[_COMMUNITY_Gap Deception Layer|Gap: Deception Layer]]
- [[_COMMUNITY_Gap UEBA|Gap: UEBA]]

## God Nodes (most connected - your core abstractions)
1. `XDR Pipeline (Collector → MSK → Flink → ML → Verdict)` - 11 edges
2. `Seven Sensor Detection Layers` - 8 edges
3. `Tetragon (eBPF In-Kernel Enforcer, Layer 1)` - 8 edges
4. `AWS GuardDuty (ML Threat Detection, Layer 6)` - 7 edges
5. `Cilium CNI + eBPF (East-West, Layer 4)` - 6 edges
6. `Enforcement API (FastAPI + Celery, boto3 Workers)` - 6 edges
7. `Transit Gateway (Shared)` - 5 edges
8. `XDR VPC (bc-xdr)` - 5 edges
9. `XDR Security Architecture (AWS)` - 5 edges
10. `Multi-VPC Network Segmentation` - 5 edges

## Surprising Connections (you probably didn't know these)
- `Transit Gateway (Shared)` --semantically_similar_to--> `AWS Transit Gateway (Inter-VPC Router)`  [INFERRED] [semantically similar]
  new-infra/guide.md → new-infra/docs/xdr-aws-explained.pdf
- `XDR VPC (bc-xdr)` --semantically_similar_to--> `Multi-VPC Network Segmentation`  [INFERRED] [semantically similar]
  new-infra/guide.md → new-infra/docs/xdr-aws-explained.pdf
- `Production VPC (bc-prd)` --semantically_similar_to--> `Production VPC Zone A`  [INFERRED] [semantically similar]
  new-infra/guide.md → new-infra/docs/xdr-aws-explained.pdf

## Hyperedges (group relationships)
- **Seven Sensors Feed XDR Pipeline for Unified Verdict** — pdf_tetragon, pdf_falco, pdf_wazuh, pdf_cilium, pdf_suricata, pdf_guardduty, pdf_dns_monitoring, pdf_xdr_pipeline [EXTRACTED 1.00]
- **Tier 0/1/2 Defense Tiers Form Independent Layered Protection** — pdf_tier0_prevention, pdf_tier1_autonomous, pdf_tier2_soar, pdf_tiered_defense_model, pdf_enforcement_api [EXTRACTED 1.00]
- **Terraform Deployment Ordering: TGW → XDR VPC → Ctrl + Prd VPCs** — guide_transit_gateway, guide_xdr_vpc, guide_control_plane_vpc, guide_production_vpc, guide_terraform_deploy [EXTRACTED 1.00]

## Communities

### Community 0 - "Multi-VPC Network Architecture"
Cohesion: 0.31
Nodes (11): Control Plane VPC (bc-ctrl), Production VPC (bc-prd), Terraform Deployment Workflow, Transit Gateway (Shared), XDR VPC (bc-xdr), Multi-VPC Network Segmentation, Network ACLs, Production VPC Zone A (+3 more)

### Community 1 - "AI-Powered Threat Intelligence"
Cohesion: 0.2
Nodes (11): Amazon Bedrock AI Investigation (Claude, RAG + ATT&CK), EKS (Elastic Kubernetes Service), Hubble (Pod Flow Observability), Rationale: Managed Services Trade OPEX for Zero Operational Overhead, MISP + OpenCTI (Threat Intelligence / CTI), MITRE ATT&CK Framework, No Email/Phishing Detection Gap (MITRE T1566), OpenSearch Service (SIEM, 2200+ Sigma Rules) (+3 more)

### Community 2 - "AWS Native Security Services"
Cohesion: 0.24
Nodes (10): AWS CloudTrail (API Audit Logging), AWS GuardDuty (ML Threat Detection, Layer 6), AWS Inspector (Vulnerability Scanning), AWS Macie (Sensitive Data Detection), Attack Scenario: Brute Force + Credential Abuse, Attack Scenario: DDoS Attack, AWS Security Hub (Findings Aggregator), Suricata NIDS (Network Layer 5, VPC Traffic Mirroring) (+2 more)

### Community 3 - "Prevention and Policy Layer"
Cohesion: 0.22
Nodes (9): Kyverno (Policy Engine, Admission Controller), AWS Shield Advanced (DDoS Protection), Sigstore (Container Image Signing), Tier 0 — Prevention (Always-On, Zero Latency), Tier 1 — Autonomous Response (<1ms to 50ms), Tiered Defense Model (Tier 0/1/2), Trivy (Container Image Vulnerability Scanning), Wazuh HIDS (Host Intrusion Detection, Layer 3) (+1 more)

### Community 4 - "Container and Network Security"
Cohesion: 0.46
Nodes (8): Cilium CNI + eBPF (East-West, Layer 4), DFIR-IRIS (Case Management + ML Feedback), Falco (Container Runtime Security, Layer 2), Attack Scenario: Container Compromise, Attack Scenario: Lateral Movement (Zone B to Zone A), Seven Sensor Detection Layers, Tetragon (eBPF In-Kernel Enforcer, Layer 1), Rationale: Tetragon Tier-1 Autonomy (Zero SOAR/Kafka Dependency)

### Community 5 - "Detection Pipeline and ML"
Cohesion: 0.29
Nodes (8): Amazon MSK (Managed Kafka, Event Buffer), Collector (nProbe + Vector, ECS Normalisation), Amazon Managed Flink (CEP + Stream Processing), XDR Fast Path (>95% Confidence, Skip AI, ~1.5-2s), ML Tier 1 — LightGBM (Fast, All Events), ML Tier 2 — CNN + GNN + Autoencoder (Deep, ~5% Events), Rationale: Amazon MSK as Shock Absorber (DDoS Spike Resilience), Triton on EKS (ML Model Serving, Spot GPU)

### Community 6 - "DNS WAF and Enforcement"
Cohesion: 0.29
Nodes (8): AWS WAF (Web Application Firewall), DNS Monitoring + Identity/Auth Logs (Layer 7), Enforcement API (FastAPI + Celery, boto3 Workers), Route 53 Query Logging, Attack Scenario: DNS Tunnel (C2 over DNS), Rationale: AWS VPC as SDN (No Separate Controller), SOAR Shuffle (Playbook Executor), Tier 2 — SOAR-Orchestrated Response (1-5s)

### Community 7 - "Gap: Encrypted Traffic"
Cohesion: 1.0
Nodes (1): No Encrypted Traffic Inspection Gap

### Community 8 - "Gap: Deception Layer"
Cohesion: 1.0
Nodes (1): No Deception Layer Gap (No Honeypots/Honeytokens)

### Community 9 - "Gap: UEBA"
Cohesion: 1.0
Nodes (1): No UEBA Gap (No User Entity Behaviour Analytics)

## Knowledge Gaps
- **20 isolated node(s):** `EKS (Elastic Kubernetes Service)`, `Research VPC Zone B`, `Network ACLs`, `AWS WAF (Web Application Firewall)`, `Wazuh Manager (EKS)` (+15 more)
  These have ≤1 connection - possible missing edges or undocumented components.
- **Thin community `Gap: Encrypted Traffic`** (1 nodes): `No Encrypted Traffic Inspection Gap`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Gap: Deception Layer`** (1 nodes): `No Deception Layer Gap (No Honeypots/Honeytokens)`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Gap: UEBA`** (1 nodes): `No UEBA Gap (No User Entity Behaviour Analytics)`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `XDR Pipeline (Collector → MSK → Flink → ML → Verdict)` connect `AI-Powered Threat Intelligence` to `AWS Native Security Services`, `Container and Network Security`, `Detection Pipeline and ML`, `DNS WAF and Enforcement`?**
  _High betweenness centrality (0.356) - this node is a cross-community bridge._
- **Why does `XDR Security Architecture (AWS)` connect `AI-Powered Threat Intelligence` to `Multi-VPC Network Architecture`, `Container and Network Security`?**
  _High betweenness centrality (0.230) - this node is a cross-community bridge._
- **Why does `Seven Sensor Detection Layers` connect `Container and Network Security` to `AI-Powered Threat Intelligence`, `AWS Native Security Services`, `Prevention and Policy Layer`, `DNS WAF and Enforcement`?**
  _High betweenness centrality (0.186) - this node is a cross-community bridge._
- **Are the 2 inferred relationships involving `Tetragon (eBPF In-Kernel Enforcer, Layer 1)` (e.g. with `Falco (Container Runtime Security, Layer 2)` and `Cilium CNI + eBPF (East-West, Layer 4)`) actually correct?**
  _`Tetragon (eBPF In-Kernel Enforcer, Layer 1)` has 2 INFERRED edges - model-reasoned connections that need verification._
- **What connects `EKS (Elastic Kubernetes Service)`, `Research VPC Zone B`, `Network ACLs` to the rest of the system?**
  _20 weakly-connected nodes found - possible documentation gaps or missing edges._
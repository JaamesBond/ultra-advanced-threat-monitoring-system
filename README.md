# UATMS — Ultra Advanced Threat Monitoring System

A production-grade, cloud-native XDR (Extended Detection and Response) platform built on AWS for Big Chemistry. Combines network intrusion detection, runtime security, threat intelligence, and SOAR automation into a fully automated, policy-enforced stack — deployed and managed entirely through CI/CD.

---

## Architecture

The platform runs across two isolated AWS VPCs connected by VPC Peering, with no Transit Gateway.

```
┌─────────────────────────────────┐         ┌──────────────────────────────────────────┐
│  bc-ctrl — The Brain            │         │  bc-prd — The Data                       │
│  10.0.0.0/16  (EC2 only)        │◄────────►  10.30.0.0/16  (EKS + security stack)   │
│                                 │ Peering │                                          │
│  ┌──────────────────────────┐   │         │  EKS 1.35  (2× t3.medium)                │
│  │ Wazuh all-in-one         │   │         │  ┌──────────────────────────────────┐    │
│  │ (Manager + Indexer +     │◄──┼─────────┼──┤ Cilium 1.19.3 (ENI mode)        │    │
│  │  Dashboard)  t3.xlarge   │   │TCP 1514 │  │ Falco 8.0.2  (modern_ebpf)      │    │
│  └──────────────────────────┘   │         │  │ Tetragon 1.6.1                   │    │
│  ┌──────────────────────────┐   │         │  │ Hubble (relay + UI)              │    │
│  │ MISP  t3.large           │◄──┼─────────┼──┤ External Secrets 0.10.7         │    │
│  │ Threat Intelligence      │   │IOC sync │  └──────────────────────────────────┘    │
│  └──────────────────────────┘   │         │                                          │
│  ┌──────────────────────────┐   │         │  DaemonSets on every node:               │
│  │ Shuffle SOAR  t3.large   │   │         │  ┌──────────────────────────────────┐    │
│  │ Docker Compose v2.2.0    │   │         │  │ Suricata 7.0.7  (IDS/IPS)        │    │
│  └──────────────────────────┘   │         │  │ Zeek 7.0.5      (NSM)            │    │
│  ┌──────────────────────────┐   │         │  │ Wazuh Agent 4.14.4               │    │
│  │ GitHub Runner  t3.small  │   │         │  └──────────────────────────────────┘    │
│  │ Self-hosted (bc-prd CI)  │   │         │                                          │
│  └──────────────────────────┘   │         │  NOMAD Oasis 1.4.2                       │
│                                 │         │  (scientific data management platform)   │
│  fck-nat (t4g.nano ARM64)       │         │  fck-nat (t4g.nano ARM64)                │
└─────────────────────────────────┘         └──────────────────────────────────────────┘
                                                         │
                                                AWS Secrets Manager
                                                VPC Endpoints (S3, ECR,
                                                STS, EC2, SSM, KMS, CWL)
```

---

## Security Stack

| Component | Version | Role |
|-----------|---------|------|
| [Cilium](https://cilium.io) | 1.19.3 | CNI (ENI mode), network policy enforcement (`policyEnforcementMode=always`), kube-proxy replacement (eBPF), WireGuard node-to-node encryption, Hubble observability |
| [Falco](https://falco.org) | 8.0.2 | Kernel-level runtime threat detection via `modern_ebpf` driver |
| [Tetragon](https://tetragon.io) | 1.6.1 | eBPF-based process-level enforcement; SIGKILL policy blocks `nc`/`nmap` |
| [Wazuh](https://wazuh.com) | 4.14.4 | SIEM — aggregates Suricata/Zeek/Falco/syslog alerts; OpenSearch backend |
| [Suricata](https://suricata.io) | 7.0.7 | Network IDS/IPS on every node; rules sync from MISP + ET Open every hour |
| [Zeek](https://zeek.org) | 7.0.5 | Network security monitor; Intel feed sync from MISP every hour |
| [MISP](https://www.misp-project.org) | latest | Threat intelligence platform; feeds Suricata rules and Zeek Intel format |
| [Shuffle](https://shuffler.io) | 2.2.0 | SOAR automation; Docker Compose on EC2 in bc-ctrl |
| [External Secrets](https://external-secrets.io) | 0.10.7 | IRSA-based sync from AWS Secrets Manager into K8s Secrets |
| [NOMAD Oasis](https://nomad-lab.eu) | 1.4.2 | Scientific data management platform on bc-prd EKS |

### Telemetry Pipeline

```
bc-prd nodes
  Suricata ──► eve.json ──► /var/log/suricata/  (hostPath)
  Zeek ──────► conn/dns/http/notice.log ──► /var/log/zeek/  (hostPath)
  Falco ─────► falco.json ──► /var/log/falco/  (hostPath)
        │
        ▼
  wazuh-agent DaemonSet
  (reads all hostPath logs)
        │
        ▼ TCP 1514 (WireGuard encrypted, VPC peering)
        │
  bc-ctrl: Wazuh Manager ──► OpenSearch Indexer ──► Dashboard

MISP IOC sync (every hour)
  zeek sidecar: misp-intel-sync ──► MISP API ──► indicators.intel (Zeek Intel)
  suricata sidecar: misp-rule-sync ──► MISP API ──► misp.rules (Suricata SIDs 9000000+)
```

---

## Network Security

All pod-to-pod and inter-node traffic on bc-prd runs through **CiliumNetworkPolicy** with `policyEnforcementMode=always` — every workload has an explicit allowlist; anything not in a policy is dropped. WireGuard encrypts all node-to-node traffic including the Wazuh telemetry path over VPC peering.

### System network policies (`new-infra/k8s/system-netpols/`)

| Policy | Protects |
|--------|---------|
| `coredns-netpol.yaml` | CoreDNS cluster-internal resolution |
| `hubble-relay-netpol.yaml` | Hubble relay ↔ Cilium agents |
| `hubble-ui-netpol.yaml` | Hubble UI ↔ relay |
| `external-secrets-netpol.yaml` | ESO → STS + Secrets Manager VPC endpoints |
| `ebs-csi-netpol.yaml` | EBS CSI node → IMDS + EC2/STS VPC endpoints |
| `cilium-health-netpol.yaml` | Inter-node Cilium health probes (port 4240) |
| `falco-netpol.yaml` | Falco → kube-apiserver |
| `cert-controller-netpol.yaml` | cert-manager controller |
| `tetragon-operator-netpol.yaml` | Tetragon operator → kube-apiserver |

### Sigma detection rules (`new-infra/k8s/sigma/rules/`)

| Rule | Detects |
|------|---------|
| `aws-cloudtrail/aws-console-login-no-mfa.yml` | Console login without MFA |
| `kubernetes/k8s-privileged-pod.yml` | Privileged pod creation (container escape vector) |

---

## Repository Layout

```
new-infra/
├── environments/
│   ├── bc-ctrl/eu-central-1/     # Control plane Terraform (VPC, EC2, Route53)
│   │   ├── vpc.tf                # VPC, fck-nat, peering accepter
│   │   ├── vm.tf                 # GitHub runner + MISP EC2
│   │   ├── wazuh-ec2.tf          # Wazuh all-in-one EC2
│   │   ├── shuffle.tf            # Shuffle SOAR EC2
│   │   └── route53.tf            # bc-ctrl.internal private zone
│   └── bc-prd/eu-central-1/      # Production Terraform (EKS + security stack)
│       ├── vpc.tf                # VPC, fck-nat, peering requester, endpoints
│       ├── eks.tf                # EKS 1.35, managed node groups, access entries
│       ├── helm-security.tf      # Cilium, Falco, Tetragon, External Secrets
│       ├── helm-nomad.tf         # NOMAD Oasis Helm release
│       ├── efs-nomad.tf          # EFS CSI + StorageClass for NOMAD
│       └── secrets-nomad.tf      # Secrets Manager paths for NOMAD
├── k8s/
│   ├── system-netpols/           # Cluster-wide Cilium policies (kustomize)
│   ├── wazuh-agent/              # Wazuh agent DaemonSet + CNP
│   ├── suricata/                 # Suricata DaemonSet + MISP sync sidecars + CNP
│   ├── zeek/                     # Zeek DaemonSet + MISP Intel sync sidecar + CNP
│   ├── tetragon/                 # Tetragon TracingPolicy (SIGKILL rules)
│   ├── nomad-oasis/              # NOMAD namespace + ExternalSecrets + CNP
│   ├── sigma/rules/              # Sigma detection rules (CloudTrail, K8s)
│   └── shuffle/                  # Shuffle Helm chart (currently on EC2)
├── modules/
│   ├── network/vpc/              # VPC + subnets + route tables
│   ├── network/vpc_peering/      # Peering requester/accepter
│   └── network/vpc/endpoints/    # VPC Interface Endpoints
├── docker/wazuh-agent/           # Wazuh agent Dockerfile (pinned 4.14.4)
└── scripts/
    ├── phase3-install-wazuh.sh   # Wazuh all-in-one bootstrap (runs at EC2 boot)
    ├── phase4-install-misp.sh    # MISP bootstrap (runs at EC2 boot)
    ├── seed-nomad-secrets.sh     # Seed NOMAD secrets from GitHub → AWS SM
    ├── victim-install-*.sh       # Detection testing: victim EC2 provisioning
    └── victim-configure-detection.sh  # Suricata rules for brute-force/portscan/DDoS
```

---

## CI/CD Pipeline

Two sequential jobs on every push to `main` under `new-infra/**`.

```
push to main
     │
     ▼
Job 1: ctrl-plane (ubuntu-latest)
  ├── Stage 1: targeted apply — VPC, fck-nat, Route53, GitHub Runner
  ├── Stage 2: full apply — reconcile all bc-ctrl resources
  └── Wait for Wazuh + MISP EC2 to be SSM-reachable
     │
     ▼
Job 2: production-plane (self-hosted runner in bc-ctrl)
  ├── State health check — fail-loud if EKS drifted from Terraform state
  ├── Stage 1: targeted apply — VPC, endpoints, fck-nat, peering, EKS
  ├── Stage 2: targeted apply — Cilium, Falco, Tetragon, External Secrets (CRD bootstrap)
  ├── Wait for CRDs to propagate
  ├── Apply K8s manifests: system-netpols → Zeek → Suricata → wazuh-agent → nomad-oasis
  └── Build + push wazuh-agent Docker image to ECR
```

OIDC-based authentication to AWS (no long-lived credentials). Terraform state in S3 with DynamoDB lock. State drift recovery available via manual `terraform-state-recovery.yml` workflow dispatch.

---

## Deployment

### Prerequisites

- AWS CLI configured with access to the deployment account
- Terraform ≥ 1.9
- `kubectl`, `helm`
- Docker (for wazuh-agent image build)

### Manual deploy

```bash
# Step 1 — bc-ctrl (all EC2 infra)
cd new-infra/environments/bc-ctrl/eu-central-1
terraform init && terraform apply

# Step 2 — bc-prd (EKS + security stack)
cd new-infra/environments/bc-prd/eu-central-1
terraform init && terraform apply

# Configure kubectl
aws eks update-kubeconfig --region eu-central-1 --name bc-uatms-prd-eks

# Apply K8s manifests
kubectl kustomize new-infra/k8s/system-netpols | kubectl apply -f -
kubectl kustomize new-infra/k8s/zeek | sed "s/\${AWS_ACCOUNT_ID}/<account-id>/g" | kubectl apply -f -
kubectl kustomize new-infra/k8s/suricata | sed "s/\${AWS_ACCOUNT_ID}/<account-id>/g" | kubectl apply -f -
kubectl kustomize new-infra/k8s/wazuh-agent | sed "s/\${AWS_ACCOUNT_ID}/<account-id>/g" | kubectl apply -f -
kubectl kustomize new-infra/k8s/nomad-oasis | kubectl apply -f -
```

### Verify the security stack

```bash
# Cilium status + WireGuard encryption
kubectl -n kube-system exec ds/cilium -- cilium status --brief
kubectl -n kube-system exec ds/cilium -- cilium encrypt status

# Hubble network flows
kubectl -n kube-system exec ds/cilium -- hubble observe --last 50
kubectl -n kube-system exec ds/cilium -- hubble observe --verdict DROPPED --last 100

# Hubble UI (port-forward)
kubectl -n kube-system port-forward svc/hubble-ui 12000:80

# Falco runtime alerts
kubectl -n falco logs -l app.kubernetes.io/name=falco -c falco --tail=20

# Tetragon process enforcement
kubectl -n kube-system logs ds/tetragon -c export-stdout --tail=20

# Sensor DaemonSets
kubectl -n suricata get pods -o wide
kubectl -n zeek get pods -o wide
kubectl -n wazuh get pods -o wide
```

---

## Key Design Decisions

**Cilium ENI mode** — Cilium manages pod IPs directly via AWS ENIs (`ipam.mode=eni`), replacing `aws-node`. This gives native VPC routing (no overlay), ENI-level security group enforcement, and Hubble observability over real AWS IPs.

**`policyEnforcementMode=always`** — Every pod that lacks a CiliumNetworkPolicy is isolated. System components (CoreDNS, EBS CSI, Hubble relay, Falco, etc.) each have an explicit allowlist policy. This is the highest-security posture Cilium supports.

**WireGuard node encryption** — All inter-node traffic (pod-to-pod across nodes, and Wazuh telemetry over VPC peering) is encrypted at the kernel level by Cilium WireGuard. No changes needed to application TLS configuration.

**Hub-spoke, no Transit Gateway** — VPC Peering keeps cross-VPC routing simple and eliminates Transit Gateway cost. bc-prd and bc-ctrl each have their own `fck-nat` instance for internet egress; neither routes internet traffic through the other.

**fck-nat over NAT Gateway** — `t4g.nano` ARM64 instances running [fck-nat](https://github.com/AndrewGuenther/fck-nat) replace AWS managed NAT Gateways. At low throughput, the cost difference is ~$32/month/NAT vs ~$4/month/instance.

**Secrets Manager + IRSA** — No credentials are stored in K8s secrets or environment variables. The External Secrets Operator syncs from AWS Secrets Manager using IAM Roles for Service Accounts (IRSA), so pods get rotating secrets without any static creds in the cluster.

---

## Cost Profile

Target: **~$565/month** baseline. Primary cost drivers:

| Resource | ~Cost/month |
|----------|------------|
| EKS cluster | $73 |
| 2× t3.medium nodes | $60 |
| Wazuh EC2 (t3.xlarge + 260 GiB EBS) | ~$130 |
| MISP EC2 (t3.large + 90 GiB EBS) | ~$75 |
| Shuffle EC2 (t3.large) | ~$50 |
| GitHub Runner EC2 (t3.small) | ~$15 |
| 2× fck-nat (t4g.nano) | ~$8 |
| VPC Endpoints, S3, ECR, misc | ~$50 |

---

## Documentation

- [`CLAUDE.md`](CLAUDE.md) — full architecture reference, resource map, critical guardrails, and troubleshooting guide
- [`SECURITY_STACK_ROLLOUT_PLAN.md`](SECURITY_STACK_ROLLOUT_PLAN.md) — phased rollout tracker with validation steps
- [`new-infra/docs/cilium-eks-security-planning.md`](new-infra/docs/cilium-eks-security-planning.md) — Cilium ENI mode design rationale and multi-VPC architecture
- [`PRE_PROD_GAPS.md`](PRE_PROD_GAPS.md) — known security gaps that must be resolved before production use

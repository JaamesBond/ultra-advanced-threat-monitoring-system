# Cilium & EKS Security Stack — Architecture Planning

**Context**: This document answers two questions in the context of the full intended platform,
not just the current 2-VPC prototype.

**Full platform vision**: One central security hub (bc-ctrl) + one security monitoring cluster
(bc-prd) + N future **research VPCs**, each running at least one EKS cluster with Nomad for
chemistry/science data processing workloads, plus additional EKS clusters for supporting
services. This repository holds the security stack only; the research VPC infrastructure lives
in separate repos.

---

## Part 1 — Cilium Use Case Assessment

### The lens that changes everything

With only bc-prd in scope, Cilium is a CNI with some observability bolted on. With N research
VPCs each running Nomad and science workloads managed by students, Cilium is the enforcement
boundary that separates experiments from each other, prevents a compromised container from
pivoting across the VPC, and gives you audit-quality flow telemetry across the whole platform.
That's a fundamentally different role.

The re-assessment below rates each use case against the full platform, not the prototype.

---

### Use cases currently active

#### ENI-mode IPAM  
**Rating: Correct, keep.**  
Each research EKS cluster in its own VPC gets native VPC IPs on pods. No overlay. Pods are
directly routable within the VPC and to VPC-peered destinations. This means Wazuh agents can
reach bc-ctrl's Wazuh manager by VPC IP without NAT, Suricata/Zeek see real source IPs, and
AWS SGs can apply at the pod level. ENI mode is the right choice for every future research
cluster and should be the enforced default in the `eks-security-stack` module.

#### CiliumNetworkPolicy L3/L4 (policyEnforcementMode=default, Phase D in progress)  
**Rating: Active but incomplete — must finish.**  
`policyEnforcementMode=default` means traffic without a CNP passes freely. This is a
transitional state during Phase D. For the full platform, every research cluster must reach
`policyEnforcementMode=always` (true default-deny) before Nomad workloads are deployed on
it. Nomad jobs from different research groups run on shared nodes — without default-deny a
job in namespace A can reach a service in namespace B over the cluster network.

**Action**: After Phase D CNPs are applied and validated with Hubble (no unexpected drops),
flip `policyEnforcementMode` from `default` to `always` in the Helm values. This is a
one-line change with a large security impact.

#### Hubble observability (relay + UI)  
**Rating: Active, under-invested — prioritise the UI ingress.**  
Hubble is the primary east-west visibility tool for the entire platform. Without it, a
security event in any research cluster is invisible until it hits Wazuh logs. With N clusters,
you need Hubble accessible as a permanent dashboard, not a port-forward. The current state
(no ingress, no auth) means Hubble is theoretical visibility, not operational visibility.

**Action**: Prioritise Hubble UI ingress. Keycloak is not yet deployed — Phase I uses AWS
Cognito as the interim OIDC provider for the ALB auth listener. Keycloak swap is a future
task once Keycloak is running. This becomes the network observability plane for the whole platform.

---

### Use cases not active — assessed for the full platform

#### Transparent Encryption (WireGuard node-to-node)  
**Current**: Off.  
**With full platform**: **Must enable.**

WireGuard (`encryption.type=wireguard`, `encryption.nodeEncryption=true`) encrypts pod-to-pod
traffic **within** a cluster (inter-node east-west). It does NOT encrypt traffic leaving the
node toward VPC-peered destinations — the WireGuard mesh terminates at the source node, and
cross-VPC traffic exits unencrypted by Cilium (bc-ctrl EC2 has no Cilium agent to terminate
the tunnel).

For Wazuh telemetry specifically: the agent–manager stream on TCP 1514 crosses VPC peering
outside the WireGuard mesh. However, Wazuh's own protocol encrypts this traffic at the
application layer via AES-256 (`<crypto_method>aes</crypto_method>` in ossec.conf). Verify
this is configured before enabling WireGuard. The primary value of Phase H WireGuard is
intra-cluster east-west encryption and defence-in-depth — not cross-VPC coverage.

CPU cost on t3.medium is roughly 5–15% at high throughput, negligible at low throughput. On
a research cluster that does chemistry simulation, most CPU is consumed by the job itself, not
network I/O.

**When to enable**: After Phase D and the `policyEnforcementMode=always` flip are stable.
Enable it per-cluster starting with bc-prd, then carry it as a default into the
`eks-security-stack` module so every research cluster gets it automatically.

**Configuration reference**:
```hcl
set {
  name  = "encryption.enabled"
  value = "true"
}
set {
  name  = "encryption.type"
  value = "wireguard"
}
set {
  name  = "encryption.nodeEncryption"
  value = "true"
}
```

#### DNS-based Network Policy (FQDN egress)  
**Current**: Off.  
**With full platform**: **Should enable — especially for research workloads.**

Nomad jobs doing chemistry data processing will call external data sources: PDB (Protein Data
Bank), ChemSpider, PubChem, NCBI, institutional data repositories. Right now, if a node can
reach the internet via fck-nat, any pod on that node can reach any internet destination on
port 443.

FQDN policies close this. You can write a CNP that says: "pods in namespace `experiment-A`
may only egress to `data.rcsb.org` and `pubchem.ncbi.nlm.nih.gov` on TCP 443. Deny
everything else." If a Nomad job is compromised, it cannot phone home to a C2 server — it
can only reach the data sources its CNP allows.

This also applies to the security stack itself. Examples already relevant in bc-prd:
- `suricata:rule-refresher` → only `rules.emergingthreats.net`
- `suricata:misp-rule-sync` → only `misp.bc-ctrl.internal`
- External Secrets Operator → only `secretsmanager.eu-central-1.amazonaws.com`

Implementation: FQDN policies require Cilium to intercept DNS responses. Cilium runs a DNS
proxy that captures resolved IPs per pod and uses them to enforce egress rules dynamically.
This has a small latency cost on DNS queries (~1ms) and is invisible to applications.

**When to enable**: After WireGuard encryption is stable. FQDN policy is Phase D+ work.

#### Bandwidth Manager  
**Current**: Off.  
**With full platform**: **Enable for research clusters, leave off for bc-prd security cluster.**

On bc-prd's security EKS, Suricata and Zeek need to receive maximum network throughput for
packet capture. Rate-limiting them is counterproductive. Bandwidth Manager should be off on
the security monitoring cluster.

On research VPC EKS clusters running Nomad, the situation is the opposite. Multiple
experiments run concurrently on shared nodes. A single chemistry simulation with high data
transfer requirements (e.g., streaming large molecular datasets) can starve other workloads
of bandwidth if uncapped. Bandwidth Manager enforces pod-level rate limits using eBPF TC
rules, respecting the `kubernetes.io/egress-bandwidth` and
`kubernetes.io/ingress-bandwidth` annotations on pods.

This means the `eks-security-stack` module should accept a parameter
`bandwidth_manager_enabled` (default `false` for the security cluster, `true` for research
clusters).

#### L7 Network Policy (HTTP/gRPC/DNS inspection)  
**Current**: Off.  
**With full platform**: **Selective use — valuable for Nomad API services.**

The current bc-prd workloads (Suricata, Zeek, wazuh-agent) speak binary protocols, not HTTP
APIs, so L7 policies add no value there.

On research VPC clusters, Nomad jobs may expose HTTP APIs to other services in the same
cluster (e.g., a chemistry computation service that accepts POST /compute requests). L7
policies let you enforce: "only pods with label `app=frontend` may POST to `/compute` on
the computation service — all other HTTP methods and paths are denied." This is a genuine
security control for API-driven research workloads.

L7 inspection in Cilium works by redirecting matched traffic through an embedded Envoy proxy.
This adds latency (~0.2–0.5ms per connection setup) and CPU overhead. Use it selectively on
services that expose HTTP APIs, not blanket across the cluster.

**When to enable**: On a per-service basis in research VPCs, defined in the Nomad workload
CNPs. Not applicable to the current bc-prd security cluster.

#### Host Firewall  
**Current**: Off.  
**With full platform**: **High value — especially for student-managed clusters.**

AWS Security Groups provide VPC-level network enforcement. Cilium Host Firewall adds a
complementary layer at the kernel level, enforced by eBPF regardless of SG state. For a
platform where students run workloads, the risk of a privileged container escape (e.g., via a
misconfigured Nomad job with `privileged: true`) is real — the two existing Sigma rules
already flag this exact pattern.

When a container escapes to the host, it's no longer a pod — it's a process running as root
on the EC2 instance. AWS SGs still apply, but Cilium Host Policies would enforce additional
kernel-level rules: "this node may only accept traffic on ports 1514, 1515 from bc-prd CIDR,
and TCP 443 from the VPC CIDR." An escaped container trying to phone out on an unexpected
port would hit the Host Policy.

**Caveat**: `hostFirewall.enabled=true` requires specifying `devices`, which conflicts with
ENI mode's dynamic ENI management. This needs careful testing. The recommended approach is to
test it on a separate branch before including it in the module.

**When to enable**: After WireGuard and FQDN policies are stable. Phase F+ work.

#### KubeProxy Replacement  
**Current**: Partially implicit (ENI mode handles pod routing, kube-proxy may still run).  
**With full platform**: **Enable explicitly — remove kube-proxy addon from every cluster.**

Across N research VPC clusters, each running the kube-proxy addon unnecessarily, this is
wasted overhead and a maintenance surface. kube-proxy maintains iptables rules that become
stale and conflicting when Cilium is also managing service routing. Replacing it completely
with Cilium eBPF (`kubeProxyReplacement=true`) is cleaner, faster for service resolution, and
removes a component that doesn't belong.

Check current state: `kubectl -n kube-system get ds kube-proxy`. If it exists, it should be
removed. In `eks.tf`, remove the `kube-proxy` cluster addon. In Cilium Helm values, add
`kubeProxyReplacement=true`.

**When to enable**: Now, if kube-proxy is confirmed running. Low risk, high clarity.

#### Cluster Mesh  
**Current**: Off.  
**With full platform**: **Do not enable — isolation is the design intent.**

Cluster Mesh connects Kubernetes clusters so pods in cluster A can reach ClusterIP services
in cluster B by name. This sounds useful for a multi-VPC research platform.

However, it contradicts the architecture's core principle: research VPCs are isolated from
each other. Cluster Mesh would create a mesh of trust across all research VPCs, allowing a
compromised job in VPC-1 to reach services in VPC-2. VPC peering already provides controlled
cross-VPC connectivity (only to bc-ctrl, only on specific ports) — Cluster Mesh would
undermine that model.

If two research groups need to share a service, the correct architecture is a shared service
VPC (like bc-ctrl today) accessed via controlled VPC peering, not Cluster Mesh.

**Exception**: If bc-prd's security EKS cluster and a research VPC's EKS cluster ever need
to share Cilium identities for cross-cluster CNP enforcement, Cluster Mesh becomes relevant.
That's a future consideration, not current.

#### Egress Gateway  
**Current**: Off.  
**With full platform**: **Possibly relevant for licensed external data sources.**

Some chemistry databases (commercial ones, institutional APIs) whitelist access by source IP.
The fck-nat instance gives a fixed public IP, but that IP is shared by all workloads in the
VPC. Egress Gateway would allow specific namespaces (e.g., `experiment-licensed-db`) to use
a dedicated Elastic IP when calling external services, while other namespaces continue using
fck-nat.

This is a future feature for research VPCs, not a current need. Flag it for when research
VPCs are being designed.

#### Mutual Authentication (mTLS via SPIFFE)  
**Current**: Off.  
**With full platform**: **Low priority — architecture makes it hard to use.**

The current workloads (DaemonSets on hostNetwork) bypass Cilium pod identity. Mutual
authentication requires pod identity via SPIFFE/SPIRE, which hostNetwork pods don't have.
For Nomad jobs in research VPCs, this could be useful if jobs expose APIs that need
caller identity verification. But it requires WireGuard encryption first, and the Nomad
workloads don't have hostNetwork requirements.

**Defer until**: WireGuard stable + research cluster CNPs defined + mTLS need confirmed
by research team.

#### BGP Control Plane  
**Not applicable in AWS VPC.** BGP is for bare-metal / on-prem routing. Every future
cluster runs in an AWS VPC with VPC-native routing. No BGP needed.

#### L2 Announcements / LoadBalancer IP Advertisement  
**Not applicable in AWS VPC.** AWS handles LoadBalancer IPs via the AWS LB Controller
and Route 53. L2 announcements are for bare-metal only.

#### Secondary Networks (Multus)  
**Low priority, worth tracking.**  
Chemistry instruments and HPC systems sometimes use specialised network protocols (e.g.,
InfiniBand, RoCE, RDMA). If a research VPC ever connects to physical lab equipment via
dedicated network interfaces, Multus + Cilium secondary networks would be the right
architecture. Not a current concern, but flag for future hardware integration discussions.

#### Big TCP  
**Low priority optimisation.**  
For chemistry simulation workloads that transfer large molecular datasets within the cluster
(node-to-node large data copies), Big TCP can reduce CPU overhead by enabling jumbo segments
in the kernel. Only relevant when CPU is measurably bottlenecked on network processing.
Can be enabled per-cluster without affecting other clusters.

#### Gateway API  
**Medium priority — standardise ingress across the platform.**  
With multiple research EKS clusters each exposing services (Nomad UI, Jupyter, custom
research APIs), a consistent ingress story matters. Cilium's Gateway API implementation
is sidecarless (unlike Istio's), uses Envoy embedded in the Cilium agent, and integrates
with CiliumNetworkPolicy for L7 enforcement on ingressed traffic. This is the recommended
ingress mechanism for research clusters once the design is finalised.

Do not use the AWS ALB Ingress Controller in research clusters if Cilium is already present
— that's two ingress planes, two sets of resources, two debugging surfaces.

#### SCTP / Multicast  
**Not applicable.** No workloads use these protocols in the current or planned stack.

---

### Summary table — Full platform priority

| Use Case | bc-prd Now | Research VPCs | Action |
|----------|-----------|---------------|--------|
| ENI IPAM | ✅ Active | Default | Encode in module |
| L3/L4 CNP | 🔶 Partial | Must-have | Finish Phase D, flip to `always` |
| Hubble observability | 🔶 No ingress | Must-have | Ingress + Keycloak auth |
| WireGuard encryption | ❌ Off | Must-have | Add after Phase D |
| FQDN/DNS policy | ❌ Off | High value | Add after WireGuard |
| KubeProxy replacement | ❌ Likely redundant | Yes | Verify + remove kube-proxy addon |
| Bandwidth Manager | ❌ Off | Research clusters only | Module param, off for security cluster |
| L7 HTTP policy | ❌ Off | Per-service in research | Not for security cluster |
| Host Firewall | ❌ Off | High value | After WireGuard, needs device testing |
| Gateway API | ❌ Off | Standard ingress | Research cluster design phase |
| Egress Gateway | ❌ Off | Future (licensed DBs) | When research VPCs designed |
| Cluster Mesh | ❌ Off | Do not use | Violates isolation model |
| mTLS / SPIFFE | ❌ Off | Future | After WireGuard + confirmed need |
| BGP | ❌ Off | N/A | Not applicable in AWS |
| L2 Announcements | ❌ Off | N/A | Not applicable in AWS |
| Bandwidth Manager | ❌ Off | Research only | Module param |
| Big TCP | ❌ Off | Optimisation | Enable if CPU-bound on data xfer |
| Secondary Networks | ❌ Off | Future hardware | Flag for lab integration |
| SCTP / Multicast | ❌ Off | N/A | Not applicable |

---

## Part 2 — Mandatory Security Stack for Future EKS Clusters

### What the question actually is

Phase F in `SECURITY_STACK_ROLLOUT_PLAN.md` proposes a `new-infra/modules/eks-security-stack/`
Terraform module that packages Cilium + Falco + Tetragon + Hubble, and wants CLAUDE.md and
the `/tf-review` skill to block any env dir with `module "eks"` but without
`module "eks-security-stack"`.

With the full platform in mind, the question is not just "should bc-prd always have the
stack" — it is "should every EKS cluster across the entire research platform always have the
stack, and how should that be enforced?"

---

### Answer: Yes, mandatory — but the module must be designed for the platform, not the prototype

#### Why mandatory

**1. This repository IS the security coverage layer for the entire platform.**  
bc-prd EKS is not "the production cluster." It is the proof-of-concept for how every research
cluster will be monitored. The intent, stated in the project overview, is to cover all research
VPCs. An EKS cluster without Cilium + Falco + Tetragon is a gap in XDR coverage — equivalent
to deploying Wazuh on some hosts but not others.

**2. Student workloads are higher risk, not lower.**  
Students testing data processing pipelines will inevitably run containers with overly broad
privileges, use images with known CVEs, and trigger runtime anomalies. Falco detects these.
Tetragon enforces kill policies. Cilium prevents lateral movement. The argument that "it's
just students testing" is precisely the reason the stack is mandatory — not a reason to
exempt test clusters.

**3. Nomad specifically needs it.**  
Nomad is a general-purpose workload scheduler. A Nomad job can be any container, not just
curated research software. Students submitting arbitrary jobs to a Nomad cluster that has no
runtime enforcement, no network policy, and no flow visibility is a significant risk surface.
This is the scenario Falco's "Terminal shell in container" rule and Tetragon's SIGKILL policy
were built for.

**4. Multi-cluster consistency prevents blind spots.**  
With N research VPCs, the attack surface scales with N. Each unmonitored cluster is a pivot
point. Mandatory stack = mandatory visibility.

**5. It amortises across the platform.**  
The cost of designing, testing, and maintaining the security stack is paid once (in this
repo). Every research cluster that calls the module gets it for free. Without the module,
each research VPC owner would need to independently configure monitoring — and they won't.

---

#### Where the current Phase F design falls short

The rollout plan's Phase F description targets the current prototype only. For the full
platform, the module needs to be designed differently:

**Problem 1: The module is tightly coupled to bc-prd.**  
The current `helm-security.tf` hardcodes the EKS cluster endpoint, OIDC provider, and IAM
role names for bc-prd. The `eks-security-stack` module must accept these as variables so it
can be called from any research VPC with any cluster.

**Problem 2: Wazuh agents need to point at the central manager.**  
The wazuh-agent DaemonSet in `new-infra/k8s/wazuh-agent/configmap.yaml` hardcodes
`wazuh-manager.bc-ctrl.internal`. Every research VPC's wazuh-agent needs to reach the same
manager. This works if: (a) every research VPC peers with bc-ctrl, and (b) the bc-ctrl.internal
Route53 zone is associated with every research VPC. The module must accept a `wazuh_manager_endpoint`
variable (defaulting to `wazuh-manager.bc-ctrl.internal`) and provision the R53 zone association
as part of its contract with the calling environment.

**Problem 3: MISP IOC sync.**  
Suricata's `misp-rule-sync` and Zeek's `misp-intel-sync` sidecars call `misp.bc-ctrl.internal`.
Same cross-VPC DNS resolution requirement. The module must document this dependency.

**Problem 4: Resource sizing.**  
A research cluster running chemistry simulations on `c5.2xlarge` nodes can afford the security
stack at default resource requests. A student testing on `t3.medium` nodes needs tuned limits.
The module must expose `resource_profile` (e.g., `small` / `standard` / `large`) that sets
appropriate Helm values for requests and limits on each component.

**Problem 5: The `eks-security-stack` module doesn't exist yet.**  
Enforcing it in CLAUDE.md and the tf-review skill before it exists creates a catch-22. The
enforcement should be added to CLAUDE.md and the skill AFTER the module is functional and
bc-prd has been refactored to use it (Phase F.2).

---

#### Correct scope of the enforcement

The Phase F tf-review skill check should block on:

```
IF env dir has module "eks"
AND environment name matches bc-* (production intent)
AND NOT module "eks-security-stack"
THEN: BLOCK with message "All bc-* EKS clusters must use module.eks-security-stack"
```

It should NOT block on:
- Scratch/dev environments outside the `bc-*` namespace
- Environments explicitly tagged `security_stack_exempt = true` with a mandatory comment
  explaining the justification (for the rare case where a temporary test cluster is
  genuinely exempt)

This gives you the mandatory guardrail while retaining a documented escape hatch for
legitimate exceptions.

---

### The eks-security-stack module — design spec

This is what Phase F should build. The module lives at
`new-infra/modules/eks-security-stack/`.

#### Inputs

```hcl
variable "cluster_name"              { type = string }
variable "cluster_endpoint"          { type = string }
variable "cluster_ca_data"           { type = string }
variable "oidc_provider_arn"         { type = string }
variable "oidc_provider"             { type = string }
variable "region"                    { type = string  default = "eu-central-1" }

# Versioning — overridable per env but with tested defaults
variable "cilium_version"            { type = string  default = "1.19.3" }
variable "falco_version"             { type = string  default = "8.0.2" }
variable "tetragon_version"          { type = string  default = "1.6.1" }
variable "external_secrets_version"  { type = string  default = "0.10.7" }

# Cilium behaviour
variable "hubble_enabled"            { type = bool    default = true }
variable "policy_enforcement_mode"   { type = string  default = "default" }  # flip to "always" when CNPs are ready
variable "wireguard_enabled"         { type = bool    default = false }       # enable after Phase D

# Resource sizing
variable "resource_profile"          {
  type    = string
  default = "standard"  # "small" | "standard" | "large"
}

# Wazuh manager — cross-VPC connectivity
variable "wazuh_manager_endpoint"    { type = string  default = "wazuh-manager.bc-ctrl.internal" }
variable "wazuh_manager_port"        { type = number  default = 1514 }

# Falco custom rules path
variable "falco_rules_file"          { type = string  default = "" }  # path relative to module caller

# Bandwidth Manager — off for security cluster, on for research clusters
variable "bandwidth_manager_enabled" { type = bool    default = false }
```

#### What the module provisions

1. `helm_release.cilium` — with all current ENI-mode settings + input variables for
   WireGuard, bandwidth manager, Hubble, policy enforcement mode
2. `helm_release.falco` — with modern eBPF driver + optional custom rules file
3. `helm_release.tetragon` — bare deployment (TracingPolicies applied separately as K8s
   manifests by the calling env)
4. `helm_release.external_secrets` — with IRSA role wired to the cluster's OIDC provider
5. `aws_iam_role.external_secrets` — IRSA role scoped to `bc/wazuh/*` and
   `bc/suricata/misp`, `bc/zeek/misp` in Secrets Manager

#### What the module does NOT provision

- Wazuh agent DaemonSet (K8s manifest, applied via kubectl kustomize — not Helm)
- Suricata DaemonSet (same)
- Zeek DaemonSet (same)
- CiliumNetworkPolicies (same — env-specific, applied via kubectl kustomize)
- TracingPolicies (same)
- Route53 zone association to bc-ctrl.internal (lives in the calling env's vpc.tf, not
  in this module — it's a VPC-level concern, not a cluster-level concern)

The module draws the line at: "everything installed via Helm into EKS." K8s manifests and
VPC-level resources belong to the calling environment.

---

### Deployment sequence for a new research VPC

When a new research VPC is created (say, `bc-research-1`), the sequence is:

```
1. bc-ctrl apply (already running — no change needed)
2. bc-research-1 Terraform:
   a. VPC + fck-nat + VPC peering to bc-ctrl
   b. Route53 zone association (bc-ctrl.internal → bc-research-1 VPC)
   c. EKS cluster
   d. module.eks-security-stack (Helm components)
3. kubectl apply K8s manifests (wazuh-agent, suricata, zeek, tetragon TracingPolicies, CNPs)
4. Validate: Wazuh manager receives agents from bc-research-1 nodes
5. Validate: Hubble shows flows in bc-research-1 cluster
6. Deploy Nomad + research workloads
```

The security stack (steps 2d + 3) must be complete BEFORE research workloads (step 6).
This ordering is enforced by CI (same staged apply pattern as bc-prd: infra → security →
workloads).

---

### Cost implications

The security stack adds the following to each research EKS cluster:

| Component | Memory (per node) | CPU (per node) | Notes |
|-----------|------------------|----------------|-------|
| Cilium agent | ~200MB | ~0.3 vCPU | Higher with Hubble enabled |
| Hubble relay | ~100MB | ~0.1 vCPU | Shared, 1 pod |
| Falco | ~150MB | ~0.2 vCPU | eBPF driver, no kernel module overhead |
| Tetragon | ~100MB | ~0.1 vCPU | kprobes are cheap |
| External Secrets | ~80MB | ~0.05 vCPU | Shared, 1 pod |
| **Total overhead** | **~630MB/node** | **~0.75 vCPU/node** | On 2×t3.medium: ~16% RAM, ~19% CPU |

On larger node types (`c5.2xlarge`, `m5.xlarge`) this overhead becomes negligible (<5%).
For student test clusters on `t3.medium`, the `resource_profile=small` variant would halve
these numbers by setting low requests and generous limits (burst-able rather than reserved).

The security stack is not optional — it is the cost of having monitoring. If cost is a
constraint, the answer is to use larger nodes for research workloads (which is correct
anyway for chemistry simulation), not to skip the stack.

---

### Open questions — status

1. **Will research VPCs be in the same AWS account or separate accounts?**  
   **Decided: Separate accounts per research VPC** (aligns with LZA multi-account model).
   Account-level blast radius isolation is the only hard boundary. A student workload
   compromise in a research account cannot affect bc-ctrl or bc-prd secrets, IAM roles, or
   CloudTrail.  
   **MVP concession:** the first research VPC may deploy into account `845517756853` provided
   the module accepts `account_id` as a variable from day one. No refactor when the second
   VPC goes to a separate account.  
   **Module implication:** `eks-security-stack` must accept `account_id` as a variable. The
   Secrets Manager resource policy on `bc/wazuh/*` needs a
   `Principal: arn:aws:iam::<research-account-id>:root` statement so the research cluster's
   External Secrets IRSA role can read it.

2. **Who provisions research VPCs — this repo's CI or separate repos?**  
   **Decided: This repo owns the module; each research VPC has its own repo consuming it via
   Git ref.**  
   ```hcl
   module "eks_security_stack" {
     source = "git::https://github.com/bigchemistry/uatms.git//new-infra/modules/eks-security-stack?ref=v1.2.0"
   }
   ```
   The security team controls version bumps. Research VPC repos pin to a semver tag and do
   not auto-update. Each research account has its own OIDC role (`GitHubActionsDeployRole-<env>`).

3. **What Nomad deployment pattern on EKS?**  
   **Decided: DaemonSet for Nomad clients (one per node), Deployment (3 replicas) for Nomad
   servers.** Matches the existing pattern of Suricata, Zeek, and wazuh-agent DaemonSets.
   Every node becomes a Nomad client, maximising scheduling fidelity and GPU access.  
   **CNP port requirements for research cluster module:**
   - Nomad server: ingress 4646 (HTTP API), 4647 (RPC), 4648 (Serf gossip) from cluster
   - Nomad client: egress to servers on 4647/4648, egress on job-specific ports per namespace
   - Nomad UI: ingress 4646 from ALB only

4. **Network isolation between research VPCs — intentional?**  
   Yes. Research VPCs must NOT peer with each other — only with bc-ctrl. The MISP sync sidecars
   reach `misp.bc-ctrl.internal` via the bc-ctrl peering link. If a research VPC ever gets its
   own MISP instance, its sidecars should point at that local MISP, not cross-VPC.

5. **Hubble multi-cluster view?**  
   With N research clusters, operating Hubble UI per-cluster is impractical. Hubble Enterprise
   (Isovalent) provides a multi-cluster view, but it's commercial. The open-source alternative
   is shipping Hubble flow data to a central Loki/Grafana stack. This should be a design
   decision before research VPCs are built, not a retrofit. **Unresolved — flag for research
   VPC design phase.**

---

## Recommended Immediate Actions

Priority order, taking the full platform into account:

| # | Action | Reason | Effort |
|---|--------|--------|--------|
| 1 | Finish Phase D CNPs, validate with Hubble DROPPED check | Unfinished work; `policyEnforcementMode=default` is allow-all without CNPs | Low |
| 2 | Flip `policyEnforcementMode` to `always` after CNP validation | True default-deny — research clusters must launch in this state | Low (1 Helm value) |
| 3 | Remove kube-proxy addon from bc-prd eks.tf, enable `kubeProxyReplacement=true` | Remove redundant component before it becomes standard in the module | Low |
| 4 | Hubble UI ingress + Keycloak auth | Observability is theoretical without a persistent dashboard | Medium |
| 5 | Enable WireGuard node encryption in bc-prd | Wazuh telemetry crosses VPC peering in plaintext | Medium |
| 6 | Design `eks-security-stack` module (Phase F) with multi-VPC inputs | Module must be built for the platform, not the prototype | High |
| 7 | Answer the open questions above (account structure, repo structure, Nomad pattern) | Module design depends on these answers | Architecture decision |
| 8 | FQDN egress policies for Suricata/Zeek rule-update sidecars | Lock rule fetching to known domains | Medium (after CNPs stable) |

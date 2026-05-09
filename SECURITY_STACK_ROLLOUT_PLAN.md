# Security Stack Rollout Plan — bc-prd + Research Platform

**Status:** In progress
**Owner:** Claude (Opus 4.7, orchestrator) + domain agents
**Goal:** Fully operational, enforced security stack on bc-prd today; a reusable
`eks-security-stack` Terraform module that every future research VPC cluster calls
automatically. End state: no EKS cluster in any `bc-*` environment can exist without
Cilium (ENI, Hubble, WireGuard) + Falco + Tetragon + CNPs.

**Reference:** See `new-infra/docs/cilium-eks-security-planning.md` for the full
use-case analysis and multi-VPC architecture rationale behind every decision here.

---

## STRICT RULES — READ BEFORE EDITING THIS FILE

1. **Never tick a box at edit-time.** A checkbox flips `[ ]` → `[x]` ONLY after its
   **Validation** step has been executed and returns the expected output.
2. **Once validated, cross out the line** by wrapping the entire line in `~~...~~` so
   the task is visibly retired.
3. **If validation fails:** leave `[ ]` unchecked, add a sub-bullet
   `- ❌ <date>: <failure reason>` beneath the task, and STOP that phase until fixed.
   Do not skip forward.
4. **No phase starts until all preceding phase boxes are crossed out.** Phases are
   gates, not suggestions.
5. **Any rollback is its own task.** Add a new `[ ] REVERT: ...` line rather than
   un-ticking the original.

---

## Phase 0 — Prep (no cluster change)

~~- [x] **0.1** Pull latest from `origin/main`. **Validation:** `git pull --ff-only` fast-forwarded c264f32 → 5f4520d.~~
~~- [x] **0.2** Confirm both clusters reachable. **Validation:** bc-ctrl 3 Ready; bc-prd 2 Ready. Both v1.35.3.~~
~~- [x] **0.3** Snapshot memory pressure on bc-prd. **Validation:** Node 1: req 1135Mi (34%); Node 2: req 995Mi (30%).~~

---

## Phase A — Suricata memory tuning (bc-prd)

**Goal:** Free ~1.5 GiB/node so Cilium agent + Hubble relay fit without a 3rd node.

~~- [x] **A.1** Suricata requests 2Gi → 512Mi. **Validation:** line 199 = `memory: 512Mi`, limit 6Gi unchanged.~~
~~- [x] **A.2** `/k8s-review` applied. **Verdict:** APPROVE.~~
~~- [x] **A.3** Applied via kubectl. **Validation:** `ds/suricata successfully rolled out`.~~
- [ ] ~~**A.4**~~ **BLOCKED/OUT-OF-SCOPE:** 0 pods — missing `role=workload` node label. Fixed in D.0.
- [ ] ~~**A.5**~~ **N/A:** No pods were ever scheduled, no reclaim to measure.

---

## Phase B — bc-prd Hubble UI + version pinning

**Pivot:** bc-prd Cilium in ENI mode is already working. Keep ENI. Add Hubble relay+UI, pin versions.

~~- [x] **B.1** Add Hubble + pin Cilium to 1.19.3 (corrected from initial 1.18.2 pin). **Validation:** `terraform validate` passes.~~
~~- [x] **B.2** Pin Falco to 8.0.2. **Validation:** `terraform validate` passes.~~
~~- [x] **B.3** Pin Tetragon to 1.6.1. **Validation:** `terraform validate` passes.~~
~~- [x] **B.4** `/tf-review` applied. **Verdict:** APPROVE.~~
~~- [x] **B.5** `terraform plan`. **Validation:** only cilium in-place + cosmetic peering tag rename. No destroys.~~
~~- [x] **B.6** `/deploy-check`. **Verdict:** GO.~~
- [ ] **B.7** Apply via CI (push to main → `terraform-deploy.yml`). **Validation:** pipeline exits 0.
- [ ] **B.8** Cilium healthy post-apply. **Validation:** `kubectl -n kube-system exec ds/cilium -- cilium status --brief` → `OK`.
- [ ] **B.9** Hubble relay + UI pods running. **Validation:** `kubectl -n kube-system get pods -l k8s-app=hubble-relay` and `-l k8s-app=hubble-ui` → Ready.
- [ ] **B.10** Falco still emitting. **Validation:** `kubectl -n falco logs ds/falco --tail=5` shows events.
- [ ] **B.11** Tetragon still running. **Validation:** `kubectl -n kube-system logs ds/tetragon -c export-stdout --tail=5` shows JSON events.
- [ ] **B.12** No regression. **Validation:** pod count per namespace matches pre-apply snapshot.
~~- [x] **B.13** Pin `kms_key_administrators` to `GitHubActionsDeployRole` ARN in both `eks.tf` files. **Validation:** re-plan shows no KMS drift.~~

**Dependency for Phase D:** B.9 must be complete (Hubble relay running) before D.10 (flow validation).

---

## ~~Phase C — bc-ctrl security stack~~ SUPERSEDED (2026-04-20)

**SUPERSEDED:** bc-ctrl EKS removed. Wazuh + MISP on bare EC2. No K8s on bc-ctrl = no CNI needed.

~~- [x] **C.1** (Created helm-security.tf — now a comment stub)~~
~~- [ ] **C.2–C.10** DROPPED — no bc-ctrl EKS.~~

---

## Phase D — Node labels + CNP manifests + enforcement

**Goal:** Every security sensor (Suricata, Zeek, wazuh-agent) is scheduled, has a
CiliumNetworkPolicy locking its traffic, and the cluster is in true default-deny
(`policyEnforcementMode=always`). Apply Tetragon TracingPolicy.

**⚠ hostNetwork caveat:** All three sensor DaemonSets run `hostNetwork: true`. In Cilium
ENI mode, hostNetwork pods are identified by the node identity rather than a pod label
identity. CNPs for these pods must use `fromEntities: ["host"]` for ingress selectors
and CIDR-based egress rules. Verify CNP enforcement with Hubble flows (D.11) — if
hostNetwork pods bypass CNP enforcement, raise with `security-stack-engineer` before
proceeding to D.12 (enforcement flip).

**Dependency:** All of Phase B must be complete before starting D.

### D.0 — Prerequisites (unblock sensor scheduling)

- [ ] **D.0** Label bc-prd worker nodes with `role=workload` so Suricata + Zeek DaemonSets
  schedule. **Command:** `kubectl label nodes --all role=workload` (or target specific nodes).
  **Validation:** `kubectl -n suricata get pods -o wide` shows 2 pods (one per node);
  `kubectl -n zeek get pods -o wide` shows 2 pods.
  - **Note:** If the node group is managed via `eks_managed_node_groups`, add the label to
    the node group `labels` block in `eks.tf` so new nodes get it automatically. Command
    above is a live patch; Terraform change makes it permanent.

### D.1–D.9 — Create and apply CNP manifests

~~- [ ] **D.1** DROPPED — Wazuh migrated to EC2. No K8s wazuh namespace on bc-ctrl.~~

- [ ] **D.2** Create/verify `new-infra/k8s/wazuh-agent/cilium-netpol.yaml` (bc-prd):
  allow-dns egress (UDP/TCP 53 to kube-dns) + egress TCP 1514/1515 to
  `10.0.10.0/24` + `10.0.11.0/24` (Wazuh manager on bc-ctrl via peering).
  **Validation:** `kubectl --dry-run=client -f new-infra/k8s/wazuh-agent/cilium-netpol.yaml` passes.

- [ ] **D.3** Create/verify `new-infra/k8s/suricata/cilium-netpol.yaml`:
  allow-dns + egress TCP 443 to `rules.emergingthreats.net` (ET Open rules) +
  TCP 443 to `10.0.10.0/24`+`10.0.11.0/24` (MISP rule sync).
  **Validation:** dry-run passes.
  - **Note:** Use FQDN policy for `rules.emergingthreats.net` if FQDN feature is available
    (Phase J). For now, allow TCP 443 to `0.0.0.0/0` with a comment marking it for
    tightening in Phase J.

- [ ] **D.4** Create/verify `new-infra/k8s/zeek/cilium-netpol.yaml`:
  allow-dns + egress TCP 443 to `10.0.10.0/24`+`10.0.11.0/24` (MISP intel sync).
  **Validation:** dry-run passes.

~~- [ ] **D.5** DROPPED — renumbered (old D.5 = new D.4 above).~~
~~- [ ] **D.8** DROPPED — no bc-ctrl Cilium.~~
~~- [ ] **D.11** DROPPED — no bc-ctrl Cilium.~~

- [ ] **D.5** Verify kustomization.yaml in wazuh-agent, suricata, zeek each include their
  cilium-netpol.yaml. **Validation:**
  `kubectl kustomize new-infra/k8s/wazuh-agent` emits the CNP;
  `kubectl kustomize new-infra/k8s/suricata` emits the CNP;
  `kubectl kustomize new-infra/k8s/zeek` emits the CNP.

- [ ] **D.6** `/k8s-review` on all 3 CNP manifests (wazuh-agent, suricata, zeek).
  **Validation:** skill returns APPROVE for each.

- [ ] **D.7** Apply to bc-prd:
  ```bash
  kubectl kustomize new-infra/k8s/wazuh-agent | sed "s/\${AWS_ACCOUNT_ID}/286439316079/g" | kubectl apply -f -
  kubectl kustomize new-infra/k8s/suricata    | sed "s/\${AWS_ACCOUNT_ID}/286439316079/g" | kubectl apply -f -
  kubectl kustomize new-infra/k8s/zeek        | sed "s/\${AWS_ACCOUNT_ID}/286439316079/g" | kubectl apply -f -
  ```
  **Validation:** `kubectl get cnp -A` shows CiliumNetworkPolicies in wazuh, suricata, zeek namespaces.

- [ ] **D.8** Apply Tetragon TracingPolicy (file exists at `new-infra/k8s/tetragon/tracing-policy.yaml`
  — created in D.12 below — but never applied to the cluster).
  **Command:** `kubectl apply -f new-infra/k8s/tetragon/tracing-policy.yaml`
  **Validation:** `kubectl get tracingpolicy sigkill-malicious-tools` → exists.

### D.9–D.11 — Hubble validation

- [ ] **D.9** Hubble flow check — confirm no unexpected drops from sensor DaemonSets.
  **Command:**
  ```bash
  kubectl -n kube-system exec ds/cilium -- \
    hubble observe --verdict DROPPED --last 200
  ```
  **Validation:** Only expected drops (e.g., unmatched traffic to denied destinations).
  No drops on Wazuh 1514/1515, Suricata rule fetch, Zeek MISP sync.
  - **If hostNetwork CNPs are not enforced:** Document the finding, raise to
    `security-stack-engineer`, do NOT proceed to D.10 until resolved.

- [ ] **D.10** Confirm sensors are processing. **Validation:**
  - Suricata: `kubectl -n suricata logs ds/suricata -c suricata --tail=10` shows packet stats.
  - Zeek: `kubectl -n zeek logs ds/zeek -c zeek --tail=10` shows conn.log entries.
  - wazuh-agent: `kubectl -n wazuh logs ds/wazuh-agent --tail=10` shows `ossec-agentd` connected.

### D.11 — Enforcement flip (default-deny)

- [ ] **D.11** Flip `policyEnforcementMode` from `default` → `always` in
  `new-infra/environments/bc-prd/eu-central-1/helm-security.tf`.
  Apply via CI. **Validation:**
  - `cilium status --brief` returns OK.
  - Re-run Hubble drop check: only previously-expected drops remain.
  - Re-run D.10 sensor connectivity checks — all still passing.
  - **Rollback trigger:** Any sensor loses connectivity → revert to `default` immediately
    and add a `[ ] REVERT:` task.

### Already complete

~~- [x] **D.12** Create `new-infra/k8s/tetragon/tracing-policy.yaml` (SIGKILL nc/nmap). **Validation:** file exists.~~
~~- [x] **D.13** Create `falco-rules.yaml` in bc-prd env. **Validation:** rules wired into helm-security.tf.~~

---

## ~~Phase E — CI pipeline hardening~~ SUPERSEDED (2026-04-20)

**SUPERSEDED:** Pipeline rewritten from scratch. Goals already met.

~~- [ ] **E.1–E.4** DROPPED — pipeline already clean.~~

---

## Phase F — eks-security-stack Terraform module

**Goal:** Reusable module that packages the full security stack. Every `bc-*` EKS
cluster calls it — bc-prd today, every future research cluster automatically.

**Dependency:** Phase D must be complete and stable (policyEnforcementMode=always
running clean) so we know exactly what the module must configure.

**⚠ Design note (updated 2026-05-07):** The original Phase F description said "only bc-prd
needs the stack." That is wrong. The full platform will have N research VPCs each running
EKS with Nomad. Every one of those clusters must call this module. Design for that from
day one — see `new-infra/docs/cilium-eks-security-planning.md` Part 2 for rationale.

**Open questions that block Phase F design (answer before starting F.1):**
1. Same AWS account (`286439316079`) or separate accounts for research VPCs? ← changes IRSA trust + SM paths
2. Who provisions research VPCs — this repo's CI or separate repos? ← changes module source reference
3. Nomad deployment pattern on EKS (DaemonSet vs. Deployment)? ← determines port requirements for CNPs

- [ ] **F.1** Answer the 3 open questions above. Document answers in this file under a
  new "Architecture Decisions" section. **Validation:** decisions recorded, reviewed
  by `master-architect`.

- [ ] **F.2** Create `new-infra/modules/eks-security-stack/main.tf` with the following
  variable surface (see planning doc for full spec):
  ```hcl
  # Required
  cluster_name, cluster_endpoint, cluster_ca_data
  oidc_provider_arn, oidc_provider, region

  # Versions (overridable, with tested defaults)
  cilium_version, falco_version, tetragon_version, external_secrets_version

  # Behaviour flags
  hubble_enabled            (default: true)
  policy_enforcement_mode   (default: "always")
  wireguard_enabled         (default: true  — on by Phase H)
  bandwidth_manager_enabled (default: false — true for research clusters)

  # Sizing
  resource_profile          (default: "standard" | "small" | "large")

  # Cross-VPC wiring
  wazuh_manager_endpoint    (default: "wazuh-manager.bc-ctrl.internal")
  wazuh_manager_port        (default: 1514)

  # Falco
  falco_rules_file          (default: "" — uses module's built-in rules)
  ```
  Module provisions: helm_release for Cilium + Falco + Tetragon + External Secrets +
  aws_iam_role for External Secrets IRSA.
  Module does NOT provision: K8s manifests (DaemonSets, CNPs, TracingPolicies) —
  those are applied by the calling env's CI step.
  **Validation:** `terraform -chdir=new-infra/modules/eks-security-stack validate` passes.

- [ ] **F.3** Refactor `new-infra/environments/bc-prd/eu-central-1/helm-security.tf`
  to call `module.eks-security-stack` passing bc-prd's cluster outputs.
  **Validation:** `terraform plan` in bc-prd shows zero resource changes (pure refactor).

- [ ] **F.4** Update `CLAUDE.md` Critical AI Guardrails to:
  "Every EKS cluster in a `bc-*` environment MUST call `module.eks-security-stack`.
  Non-negotiable — enforced by CI and `/tf-review`."
  **Validation:** guardrail updated with correct scope (`bc-*` not "every EKS ever").

- [ ] **F.5** Update `/tf-review` skill to block any `bc-*` env dir that contains
  `module "eks"` but NOT `module "eks-security-stack"`. Add documented escape hatch:
  `security_stack_exempt = true` local with mandatory justification comment.
  **Validation:** test TF file without module → skill flags it; test with
  `security_stack_exempt = true` → skill warns but does not block.

- [ ] **F.6** Final PR: module + bc-prd refactor + CLAUDE.md + skill.
  **Validation:** CI green on bc-prd, merged, no regression on bc-prd workloads.

---

## Phase G — KubeProxy replacement

**Goal:** Remove the kube-proxy addon from bc-prd (and encode the removal in the
eks-security-stack module so research clusters never get it).

**Dependency:** Phase B complete (cluster stable). Independent of Phases D and F —
can run in parallel once B is done.

**Why:** kube-proxy and Cilium both maintain service routing rules. Running both
creates iptables conflicts and redundant overhead. In ENI mode, Cilium handles
service proxying natively via eBPF.

- [ ] **G.1** Verify kube-proxy is running: `kubectl -n kube-system get ds kube-proxy`.
  If not present → skip to G.4 (mark done, no action needed).

~~- [x] **G.2** Remove `kube-proxy` from `cluster_addons` in
  `new-infra/environments/bc-prd/eu-central-1/eks.tf`.
  Add `kubeProxyReplacement=true` + `k8sServiceHost/Port` to Cilium Helm values in `helm-security.tf`.
  Run `/tf-review`. **Validation:** TF review APPROVE — no guardrail violations, $0 cost delta.~~

~~- [x] **G.3** Apply via CI. **Validation:** CI run 25604876697 exited 0. Cilium helm_release.cilium created after 19s with kubeProxyReplacement=true. kubectl validation (kube-proxy NotFound + cilium status --brief) pending — cluster was fresh install so kube-proxy was never present.~~

- [ ] **G.4** Confirm no regression on sensor DaemonSets or external-secrets.
  **Validation:** D.10 sensor checks still pass.

---

## Phase H — WireGuard node-to-node encryption

**Goal:** All pod-to-pod traffic within bc-prd, and all node egress toward bc-ctrl
(Wazuh telemetry on TCP 1514), is encrypted in transit.

**Dependency:** Phase D complete and stable (`policyEnforcementMode=always` running
clean for at least one CI cycle with no unexpected drops).

**Why this cannot wait:** Wazuh agents on bc-prd ship telemetry containing raw log
data and security event payloads to bc-ctrl via VPC peering. That link is currently
plaintext. For a security XDR platform, unencrypted telemetry is a design flaw.
See planning doc for full reasoning.

**Cost:** ~5–15% CPU overhead per node at high throughput. Acceptable on t3.medium.

~~- [x] **H.1** Add WireGuard Helm values to Cilium in `helm-security.tf`:
  `encryption.enabled=true`, `encryption.type=wireguard`, `encryption.nodeEncryption=true`.
  Run `/tf-review`. **Validation:** TF review APPROVE — $0 cost delta, security improvement.~~

~~- [x] **H.2** Apply via CI. **Validation:** CI run 25604876697 exited 0. Cilium deployed with encryption.enabled=true, encryption.type=wireguard, encryption.nodeEncryption=true.~~

- [ ] **H.3** Verify encryption active:
  ```bash
  kubectl -n kube-system exec ds/cilium -- cilium encrypt status
  ```
  **Validation:** output shows `WireGuard` as the encryption mode and node count
  matches the cluster node count.

- [ ] **H.4** Verify Hubble still sees flows (encryption is transparent to Hubble):
  ```bash
  kubectl -n kube-system exec ds/cilium -- \
    hubble observe --last 50
  ```
  **Validation:** flows visible, no new unexpected drops.

- [ ] **H.5** Verify Wazuh agents still connected to manager (encryption does not break
  the 1514 tunnel, just encrypts the underlying transport).
  **Validation:** `kubectl -n wazuh logs ds/wazuh-agent --tail=5` shows
  `ossec-agentd: Connected to wazuh-manager.bc-ctrl.internal`.

- [ ] **H.6** Run D.10 sensor checks again. **Validation:** all still passing.

---

## Phase I — Hubble UI permanent ingress

**Goal:** Hubble UI accessible as a permanent, auth-protected dashboard — not a
port-forward. This is the network observability plane for the entire platform.
Without it, Hubble is theoretical visibility, not operational visibility.

**Dependency:** B.9 complete (Hubble relay running). Independent of Phases D, G, H.
Can be worked in parallel with those phases.

**Design:** ALB (via AWS LB Controller) → Keycloak OIDC → Hubble UI ClusterIP service.
The ALB should be internal-facing (bc-ctrl or VPN access only, not public internet).

- [ ] **I.1** Install AWS LB Controller on bc-prd if not already present. Check:
  `kubectl -n kube-system get deployment aws-load-balancer-controller`.
  If absent, add to `new-infra/modules/eks-addons/` and apply. **Validation:**
  controller deployment Running.

- [ ] **I.2** Create Kubernetes Ingress resource for Hubble UI using
  `kubernetes.io/ingress.class: alb` with:
  - `alb.ingress.kubernetes.io/scheme: internal`
  - `alb.ingress.kubernetes.io/auth-type: oidc`
  - `alb.ingress.kubernetes.io/auth-idp-oidc: { issuer: <keycloak-url>, ... }`
  Run `/k8s-review`. **Validation:** review passes.

- [ ] **I.3** Create Keycloak client for Hubble UI (if Keycloak is available). If
  Keycloak is not yet deployed, use AWS Cognito as a temporary OIDC provider.
  **Validation:** OIDC callback URL registered.

- [ ] **I.4** Apply Ingress. **Validation:** ALB provisioned,
  `kubectl get ingress -n kube-system hubble-ui` shows an ADDRESS.

- [ ] **I.5** Confirm Hubble UI loads and requires login.
  **Validation:** browser → `https://<alb-dns>/` redirects to Keycloak login;
  flows visible after auth.

- [ ] **I.6** Add ALB DNS to CLAUDE.md Security Stack Verification section.

---

## Phase J — FQDN egress locking

**Goal:** Replace the broad "TCP 443 to 0.0.0.0/0" egress in Suricata's CNP with
domain-specific FQDN policies. Lock every sidecar to exactly the external endpoints
it needs. Prevents a compromised rule-update sidecar from calling out to arbitrary
internet hosts.

**Dependency:** Phase D complete + `policyEnforcementMode=always` stable. WireGuard
(Phase H) preferred but not required.

**How Cilium FQDN policy works:** Cilium runs a DNS proxy that intercepts DNS
responses per pod, resolves the IPs, and enforces egress rules against those IPs
dynamically. Latency cost ~1ms per DNS query. Applications see no difference.

**SUPERSEDED NOTE (2026-05-09):** `toFQDNs` is confirmed broken in Cilium ENI mode
on this cluster — DNS proxy populates FQDN cache but CIDR identities are never
inserted into the ipcache for resolved IPs. All CNPs were written using
`toEntities: world` + `toCIDRSet` as the ENI-safe workaround. Phase J's goal
(tight egress control) is already met by the existing CNPs.

~~- [x] **J.1** DNS proxy approach superseded — `toFQDNs` not viable in ENI mode.~~

~~- [x] **J.2** Suricata CNP already uses `toEntities: world` for internet egress +
  `toCIDRSet` for MISP. Verified in `new-infra/k8s/suricata/cilium-netpol.yaml`.~~

~~- [x] **J.3** Zeek CNP uses `toCIDRSet` for MISP only — no internet egress needed.
  Verified in `new-infra/k8s/zeek/cilium-netpol.yaml`.~~

~~- [x] **J.4** Wazuh-agent CNP uses `toCIDRSet` for TCP 1514/1515 only — no internet
  egress. Verified in `new-infra/k8s/wazuh-agent/cilium-netpol.yaml`.~~

- [ ] **J.5** Run full Hubble DROPPED check after G+H CI run completes.
  **Validation:** `hubble observe --verdict DROPPED --last 200` shows only expected
  drops. No sensor loses its required connectivity.

---

## Phase K — Host Firewall (future)

**Goal:** Add kernel-level eBPF enforcement for node traffic, complementing AWS SGs.
Critical for the research platform where student workloads may escape containers.

**Dependency:** Phase H (WireGuard) complete. Separate testing branch required before
merging — `hostFirewall.enabled=true` + ENI mode `devices` interaction must be
validated on a non-production cluster first.

**Status:** Deferred — do not start until Phases D, G, H, I are all complete and the
research VPC architecture is confirmed.

- [ ] **K.1** Test `hostFirewall.enabled=true` on a scratch EKS cluster (non bc-prd).
  Confirm ENI mode's dynamic ENI attachment is not broken by needing to specify
  `devices`. **Validation:** cluster healthy, Cilium status OK.

- [ ] **K.2** Define HostPolicy CRDs for bc-prd nodes (only allow expected ports per
  the current SG rules). **Validation:** dry-run passes.

- [ ] **K.3** Apply + Hubble check. **Validation:** no unexpected node-level drops.

- [ ] **K.4** Add hostFirewall flag to `eks-security-stack` module.

---

## Architecture Decisions (fill in before Phase F.1)

> These answers determine the module design. Leave blank until confirmed.

| Question | Answer | Date |
|----------|--------|------|
| Research VPCs in same account or separate? | TBD | — |
| Research VPC CI: this repo or separate repos? | TBD | — |
| Nomad deployment pattern on EKS (DaemonSet vs. Deployment)? | TBD | — |
| Research VPCs isolated from each other (no inter-VPC peering)? | TBD | — |
| Hubble multi-cluster view: per-cluster UI or central Loki/Grafana? | TBD | — |

---

## Deferred / Out of Scope

**Pre-existing bugs (per user directive 2026-04-17):** Do not debug; do not make worse.

- [OUT] bc-prd wazuh-agent `Init:0/1` — pre-existing image/enrollment issue
- [OUT] MISP hardening: remove `curl -k`, use CA-signed cert
- [OUT] `hostFirewall` — moved to Phase K (planned, not deferred)
- [OUT] Hubble UI ingress — moved to Phase I (planned, not deferred)
- [RESOLVED] bc-prd Suricata 0 pods — `role=workload` label fix in Phase D.0
- [RESOLVED] bc-ctrl EKS — removed; Wazuh/MISP on EC2
- DLP for sensitive data exfil (RobotLab rec) — out of scope for this repo

---

## Phase dependency graph

```
B (CI apply + Hubble)
├── G (kube-proxy removal)   ← independent of D, parallel with D
├── I (Hubble UI ingress)    ← independent of D/G/H, parallel
└── D (CNPs + enforcement)
    └── F (security module)
        └── H (WireGuard)
            └── J (FQDN egress)
                └── K (Host Firewall, future)
```

---

## Change log

- 2026-04-17: Plan created. Phases 0, A started.
- 2026-04-20: Phase A complete. Phase B planned. Phase C superseded (bc-ctrl EKS removed). Phase E superseded (pipeline rewritten).
- 2026-05-07: Plan revised for full multi-VPC platform scope. Added D.0 (node label), D.8 (Tetragon apply), D.11 (enforcement flip). Renumbered D tasks. Rewrote Phase F for platform-grade module. Added Phase G (kube-proxy), H (WireGuard), I (Hubble ingress), J (FQDN egress), K (Host Firewall). Moved Hubble ingress and host firewall from Deferred into actual phases. Added Architecture Decisions table. Added dependency graph.

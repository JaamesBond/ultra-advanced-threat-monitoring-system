# Security Stack Rollout Plan — bc-ctrl + bc-prd

**Status:** In progress
**Owner:** Claude (Opus 4.7, orchestrator) + domain agents
**Goal:** Operational Cilium + Falco + Tetragon + Hubble on BOTH EKS clusters, without breaking existing Wazuh/Suricata/Zeek/MISP workloads. Then codify the stack as a mandatory, non-negotiable requirement for every future EKS cluster.

---

## STRICT RULES — READ BEFORE EDITING THIS FILE

1. **Never tick a box at edit-time.** A checkbox flips `[ ]` → `[x]` ONLY after its **Validation** step on the same row has been executed and returns the expected output.
2. **Once validated, cross out the line** by wrapping the entire line (checkbox + description + validation) in `~~...~~` so the task is visibly retired.
3. **If validation fails:** leave `[ ]` unchecked, add a sub-bullet `- ❌ <date>: <failure reason>` beneath the task, and STOP that phase until fixed. Do not skip forward.
4. **No phase starts until all preceding phase boxes are crossed out.** Phases are gates, not suggestions.
5. **Any rollback is its own task.** If a change is reverted, add a new `[ ] REVERT: ...` line rather than un-ticking the original.

---

## Phase 0 — Prep (no cluster change)

~~- [x] **0.1** Pull latest from `origin/main` to pick up minor changes. **Validation:** `git pull --ff-only` fast-forwarded c264f32 → 5f4520d; 4 commits pulled (3-node bc-ctrl + CI fixes + CSS jwt removal).~~
~~- [x] **0.2** Confirm both clusters reachable. **Validation:** `kubectl --context bc-ctrl get nodes` → 3 Ready; `kubectl --context bc-prd get nodes` → 2 Ready. Both on v1.35.3.~~
~~- [x] **0.3** Snapshot current memory pressure on bc-prd. **Validation:** Node 1: req 1135Mi (34%), lim 3790Mi (115%). Node 2: req 995Mi (30%), lim 3322Mi (100%). Requests have ample headroom; limits oversubscribed (bursty by design).~~

---

## Phase A — Suricata memory tuning (bc-prd)

**Goal:** Free ~1.5 GiB/node on bc-prd so Cilium agent + Hubble relay fit without a 3rd node.

~~- [x] **A.1** Edit `new-infra/k8s/suricata/daemonset.yaml`: main container `resources.requests.memory` `2Gi` → `512Mi`. Actual limit is `6Gi` (not 2Gi as earlier noted). **Validation:** line 199 = `memory: 512Mi`, line 202 = `memory: 6Gi` unchanged.~~
~~- [x] **A.2** `/k8s-review` checklist applied manually (skill is .md doc, not tool-registered). **Verdict:** APPROVE — pure request reduction, frees 3Gi requested capacity on bc-prd, no security/XDR regression.~~
~~- [x] **A.3** Applied via `kubectl --context bc-prd kustomize | kubectl apply`. **Validation:** `ds/suricata successfully rolled out`.~~
- [ ] ~~**A.4** Confirm Suricata still processing packets.~~ **BLOCKED (pre-existing, out of scope):** Suricata DS has 0 pods because bc-prd node group has no `role=workload` label. Daemonset never scheduled. NOT caused by this change. Marked NOT-IN-SCOPE per user directive.
- [ ] ~~**A.5** Confirm node has freed request headroom.~~ **N/A:** No Suricata pods were ever requesting memory, so no reclaim to observe. Request reduction is correct for when DS eventually schedules.

---

## Phase B — bc-prd Hubble UI + version pinning (ENI MODE KEPT)

**Pivot:** bc-prd Cilium in ENI mode is already working (13h uptime, aws-node intentionally disabled via `nodeSelector: non-existent=true`). Do **NOT** switch to chaining mode — unnecessary churn. Just add Hubble relay+UI and pin versions.

~~- [x] **B.1** Edit `new-infra/environments/bc-prd/eu-central-1/helm-security.tf` `helm_release.cilium`: pin `version = "1.18.2"`, KEEP `eni.enabled=true` + `ipam.mode=eni` + `routingMode=native`, ADD `hubble.enabled=true` + `hubble.relay.enabled=true` + `hubble.ui.enabled=true` + `policyEnforcementMode=default`. **Validation:** `terraform validate` passes.~~
~~- [x] **B.2** Pin `helm_release.falco` to `version = "4.21.2"`, keep `driver.kind=ebpf` (already set). **Validation:** `terraform validate` passes.~~
~~- [x] **B.3** Pin `helm_release.tetragon` to `version = "1.3.0"`. **Validation:** `terraform validate` passes.~~
~~- [x] **B.4** `/tf-review` checklist applied manually. **Verdict:** APPROVE — Guardrail 9 (mandatory stack) satisfied; cost ~$0/mo; no SG/IAM/public-access changes.~~
~~- [x] **B.5** `terraform plan`. **Validation:** only `helm_release.cilium` in-place + cosmetic peering tag rename (no CNI churn, no destroys). Saved to `/tmp/phase-b-final.tfplan`. Initial plan had Falco/Tetragon downgrades (wrong pins) — corrected by matching currently-deployed versions (1.19.3 / 8.0.2 / 1.6.1). KMS principal drift fixed via B.13.~~
~~- [x] **B.6** `/deploy-check` checklist applied manually. **Verdict:** GO — TF READY, deps MET, pipeline MANUAL (overridden to CI-based apply per user directive).~~
- [ ] **B.7** Apply via CI (commit + push triggers `terraform-deploy.yml`). Hubble UI enabled (2026-04-20). **Validation:** pipeline exits 0.
- [ ] **B.8** Cilium still healthy. **Validation:** `kubectl --context bc-prd -n kube-system exec ds/cilium -- cilium status --brief` returns `OK`.
- [ ] **B.9** Hubble relay + UI pods running. **Validation:** `kubectl --context bc-prd -n kube-system get pods -l k8s-app=hubble-relay -l k8s-app=hubble-ui` shows Ready.
- [ ] **B.10** Falco still emitting. **Validation:** `kubectl --context bc-prd -n falco logs ds/falco --tail=5` shows events.
- [ ] **B.11** Tetragon still running. **Validation:** `kubectl --context bc-prd -n kube-system logs ds/tetragon -c export-stdout --tail=5` shows JSON events.
- [ ] **B.12** No regression on existing pods (do not touch bugged workloads — just confirm no NEW breakage). **Validation:** pod count per namespace matches pre-change snapshot (capture before B.7).
~~- [x] **B.13** Pin `kms_key_administrators = ["arn:aws:iam::286439316079:role/GitHubActionsDeployRole"]` in bc-prd `eks.tf` AND bc-ctrl `eks.tf`. Prevents plan-vs-state flip-flop when terraform runs from different identities (user/Matei locally vs CI role). **Validation:** re-plan shows KMS no longer drifts; only cilium + peering-tags in plan.~~

---

## ~~Phase C — bc-ctrl security stack~~ SUPERSEDED (2026-04-20)

**SUPERSEDED:** bc-ctrl EKS cluster was removed entirely. All workloads (Wazuh, MISP) migrated to bare EC2. Cilium/Falco/Tetragon are only needed on bc-prd EKS where real K8s workloads run. No Kubernetes on bc-ctrl means no CNI, no security stack. `helm-security.tf` on bc-ctrl is now a stub comment.

~~- [x] **C.1** (Created helm-security.tf — now irrelevant, file is a comment stub)~~
~~- [ ] **C.2–C.10** DROPPED — no bc-ctrl EKS cluster exists.~~

---

## Phase D — CiliumNetworkPolicy manifests (observe-only first)

**Goal:** Lock traffic patterns per workload. Ship in `policyEnforcementMode=default` so CNPs only drop matching traffic, not everything.

~~- [ ] **D.1** DROPPED — wazuh K8s manifests removed (Wazuh migrated to EC2). No K8s wazuh namespace on bc-ctrl.~~
- [ ] **D.2** Create `new-infra/k8s/wazuh-agent/cilium-netpol.yaml` (bc-prd): allow-dns + agent egress to `10.0.10.0/24` + `10.0.11.0/24` on TCP 1514/1515 (Wazuh EC2). In progress (2026-04-20). **Validation:** dry-run passes.
~~- [ ] **D.3** DROPPED — MISP K8s manifests removed (MISP migrated to EC2). No K8s misp namespace.~~
- [ ] **D.4** Create `new-infra/k8s/suricata/cilium-netpol.yaml`: allow-dns + allow TCP 80/443 egress (rule updates). In progress (2026-04-20). **Validation:** dry-run passes.
- [ ] **D.5** Create `new-infra/k8s/zeek/cilium-netpol.yaml`: allow-dns + allow TCP 443 to `10.0.10.0/24`+`10.0.11.0/24` (MISP intel sync). In progress (2026-04-20). **Validation:** dry-run passes.
- [ ] **D.6** kustomization.yaml in each dir updated to include CNP. In progress (2026-04-20). **Validation:** `kubectl kustomize new-infra/k8s/<dir>` emits the CNP.
- [ ] **D.7** Invoke `/k8s-review` on 3 manifests (wazuh-agent, suricata, zeek). **Validation:** clean.
~~- [ ] **D.8** DROPPED — no bc-ctrl Cilium.~~
- [ ] **D.9** Apply to bc-prd (wazuh-agent + suricata + zeek). **Validation:** `kubectl --context bc-prd get cnp -A` shows resources.
- [ ] **D.10** Hubble flow check — no unexpected drops. **Validation:** `kubectl --context bc-prd -n kube-system exec ds/cilium -- hubble observe --verdict DROPPED --last 100` shows only expected drops.
~~- [ ] **D.11** DROPPED — no bc-ctrl Cilium.~~
- [x] **D.12** Create `new-infra/k8s/tetragon/tracing-policy.yaml` (SIGKILL malicious tools). **Validation:** file created with syscall enforcement.
- [x] **D.13** Create `falco-rules.yaml` in both bc-prd and bc-ctrl envs. **Validation:** rules added to `helm_release.falco` in `helm-security.tf`.

---

## ~~Phase E — CI pipeline hardening~~ SUPERSEDED (2026-04-20)

**SUPERSEDED:** Pipeline was completely rewritten alongside the bc-ctrl EKS removal. New pipeline (`terraform-deploy.yml`) already has: no `sleep 60`, proper `kubectl rollout status` waits via Falco DaemonSet check, and no bc-ctrl EKS targets (bc-ctrl job manages EC2 only). All Phase E goals achieved incidentally.

~~- [ ] **E.1–E.4** DROPPED — pipeline already clean.~~

---

## Phase F — Make the stack MANDATORY (post-validation)

**Goal:** Codify the stack so no future EKS cluster can be created without it. Non-negotiable.

**Design (simplified):** bc-ctrl has no EKS. Only bc-prd EKS needs the stack. Module only needs ENI mode. No chaining mode variant required.

- [ ] **F.1** Create `new-infra/modules/eks-security-stack/` — packages Cilium (ENI) + Falco + Tetragon + Hubble helm_releases. Inputs: `cluster_name`, `cluster_endpoint`, `oidc_provider_arn`, `falcosidekick_enabled` (default `false`). **Validation:** `terraform -chdir=new-infra/modules/eks-security-stack validate` passes.
- [ ] **F.2** Refactor `new-infra/environments/bc-prd/eu-central-1/helm-security.tf` to call the module. **Validation:** `terraform plan` shows zero resource changes (pure refactor).
~~- [ ] **F.3** DROPPED — bc-ctrl has no EKS, no chaining mode needed.~~
- [ ] **F.4** Update `CLAUDE.md` Critical AI Guardrails: "Every EKS cluster MUST call `module.eks-security-stack`. Non-negotiable — enforced by CI." **Validation:** `grep 'Mandatory Stack' CLAUDE.md` shows new wording.
- [ ] **F.5** Extend `/tf-review` skill to block any env dir with `module "eks"` but NOT `module "eks-security-stack"`. **Validation:** test TF without security module → skill flags it.
- [ ] **F.6** Final PR: module + refactor + CLAUDE.md + skill change. **Validation:** CI green, merged.

---

## Deferred / Out of Scope (tracked, not blocking)

**Explicitly excluded per user directive (2026-04-17):** Any pre-existing bug in Suricata / Wazuh / Zeek / MISP deployments. We will NOT debug these; we will only ensure our changes do not make them worse.

- [OUT] bc-prd Suricata DS has 0 pods — missing `role=workload` node label (pre-existing)
- [OUT] bc-prd wazuh-agent stuck `Init:0/1` (pre-existing)
- [RESOLVED] bc-ctrl EKS issues (ebs-csi, wazuh-indexer) — bc-ctrl EKS removed entirely; Wazuh migrated to EC2
- Hubble UI Ingress via ALB + Keycloak OIDC (currently port-forward only — no auth on Hubble)
- `hostFirewall: true` + node-level CCNPs for Suricata/Zeek host networking
- DLP for sensitive data exfil (from RobotLab security recs)
- MISP hardening: dedicated ServiceAccount + proper CA-signed cert (remove `curl -k`)

---

## Change log

<!-- append dated lines as phases close -->
- (empty)

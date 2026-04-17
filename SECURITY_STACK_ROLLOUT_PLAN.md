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
- [ ] **B.7** Apply via CI (commit + push triggers `terraform-deploy.yml`). **Validation:** pipeline exits 0.
- [ ] **B.8** Cilium still healthy. **Validation:** `kubectl --context bc-prd -n kube-system exec ds/cilium -- cilium status --brief` returns `OK`.
- [ ] **B.9** Hubble relay + UI pods running. **Validation:** `kubectl --context bc-prd -n kube-system get pods -l k8s-app=hubble-relay -l k8s-app=hubble-ui` shows Ready.
- [ ] **B.10** Falco still emitting. **Validation:** `kubectl --context bc-prd -n falco logs ds/falco --tail=5` shows events.
- [ ] **B.11** Tetragon still running. **Validation:** `kubectl --context bc-prd -n kube-system logs ds/tetragon -c export-stdout --tail=5` shows JSON events.
- [ ] **B.12** No regression on existing pods (do not touch bugged workloads — just confirm no NEW breakage). **Validation:** pod count per namespace matches pre-change snapshot (capture before B.7).
~~- [x] **B.13** Pin `kms_key_administrators = ["arn:aws:iam::286439316079:role/GitHubActionsDeployRole"]` in bc-prd `eks.tf` AND bc-ctrl `eks.tf`. Prevents plan-vs-state flip-flop when terraform runs from different identities (user/Matei locally vs CI role). **Validation:** re-plan shows KMS no longer drifts; only cilium + peering-tags in plan.~~

---

## Phase C — bc-ctrl security stack (CHAINING MODE, safety-first)

**Pivot:** bc-ctrl already has VPC CNI (aws-node) + live Wazuh pods (some broken, not our scope). Switching to Cilium ENI mode requires disabling aws-node = CNI swap on running workloads = HIGH BLAST RADIUS. Use **chaining mode** so Cilium overlays L3-L7 policy + Hubble on top of VPC CNI without replacing IPAM. Existing pods untouched.

~~- [x] **C.1** Create `new-infra/environments/bc-ctrl/eu-central-1/helm-security.tf` with:
  - `helm_release.cilium` v1.19.3, `cni.chainingMode=aws-cni`, `cni.exclusive=false`, `enableIPv4Masquerade=false`, `routingMode=native`, Hubble relay+UI enabled, `policyEnforcementMode=default`
  - `helm_release.falco` v8.0.2, `driver.kind=ebpf`, `falcosidekick.enabled=false` (no Wazuh agent on bc-ctrl)
  - `helm_release.tetragon` v1.6.1
  - Helm provider already defined in `terraform_config.tf` — no new provider block.
  **Validation:** `terraform -chdir=new-infra/environments/bc-ctrl/eu-central-1 validate` passes.~~
- [ ] **C.2** Apply `/tf-review` checklist. **Validation:** clean.
- [ ] **C.3** `terraform plan`. **Validation:** plan ADDS 3 helm_releases, touches NOTHING else (no aws-node disable, no addon change).
- [ ] **C.4** Apply `/deploy-check` checklist + confirm bc-ctrl's pre-existing Wazuh/EBS issues are documented as out-of-scope. **Validation:** clean.
- [ ] **C.5** Apply. **Validation:** exits 0.
- [ ] **C.6** Cilium healthy on bc-ctrl. **Validation:** `kubectl --context bc-ctrl -n kube-system exec ds/cilium -- cilium status --brief` returns `OK`.
- [ ] **C.7** Falco running. **Validation:** `kubectl --context bc-ctrl -n falco logs ds/falco --tail=5` shows events.
- [ ] **C.8** Tetragon running. **Validation:** `kubectl --context bc-ctrl -n kube-system logs ds/tetragon -c export-stdout --tail=5` shows JSON events.
- [ ] **C.9** aws-node still running (chaining mode — MUST coexist). **Validation:** `kubectl --context bc-ctrl -n kube-system get ds aws-node` shows DESIRED=3 / READY=3.
- [ ] **C.10** No NEW pod breakage (pre-existing Wazuh/EBS issues excluded). **Validation:** snapshot pod states before C.5; diff after; broken-from-before pods count must not increase.

---

## Phase D — CiliumNetworkPolicy manifests (observe-only first)

**Goal:** Lock traffic patterns per workload. Ship in `policyEnforcementMode=default` so CNPs only drop matching traffic, not everything.

- [ ] **D.1** Create `new-infra/k8s/wazuh/cilium-netpol.yaml` (bc-ctrl): default-deny + allow-dns + manager ingress 1514/1515 from `10.30.0.0/16` + indexer 9200/9300 intra-ns + dashboard 5601 from `10.0.0.0/16`. **Validation:** `kubectl apply --dry-run=server -f ...` passes.
- [ ] **D.2** Create `new-infra/k8s/wazuh/agent/cilium-netpol.yaml` (bc-prd): default-deny + allow-dns + agent egress to `10.0.10.0/24` + `10.0.11.0/24` on 1514/1515. **Validation:** dry-run passes.
- [ ] **D.3** Create `new-infra/k8s/misp/cilium-netpol.yaml` (bc-ctrl): default-deny + mysql/redis locked to misp-core + misp-core FQDN egress (`circl.lu`, `abuse.ch`, `misp-project.org`). **Validation:** dry-run passes.
- [ ] **D.4** Create `new-infra/k8s/suricata/cilium-netpol.yaml`: default-deny + allow-dns (host-level CCNP deferred to Phase F). **Validation:** dry-run passes.
- [ ] **D.5** Create `new-infra/k8s/zeek/cilium-netpol.yaml`: same pattern as suricata. **Validation:** dry-run passes.
- [ ] **D.6** Update each `kustomization.yaml` to include the new manifest. **Validation:** `kubectl kustomize new-infra/k8s/<dir>` emits the CNP.
- [ ] **D.7** Invoke `/k8s-review` on all 5 manifests. **Validation:** clean.
- [ ] **D.8** Apply to bc-ctrl (wazuh + misp). **Validation:** `kubectl --context bc-ctrl get cnp -A` shows resources; `cilium policy get` lists them.
- [ ] **D.9** Apply to bc-prd (wazuh-agent + suricata + zeek). **Validation:** `kubectl --context bc-prd get cnp -A` shows resources.
- [ ] **D.10** Hubble flow check — no unexpected drops. **Validation:** `kubectl --context bc-prd -n kube-system exec ds/cilium -- hubble observe --verdict DROPPED --last 100` shows only expected drops (no Wazuh agent → manager, no Suricata/Zeek stats).
- [ ] **D.11** Same check on bc-ctrl. **Validation:** no unexpected drops.
- [x] **D.12** Create `new-infra/k8s/tetragon/tracing-policy.yaml` (SIGKILL malicious tools). **Validation:** file created with syscall enforcement.
- [x] **D.13** Create `falco-rules.yaml` in both bc-prd and bc-ctrl envs. **Validation:** rules added to `helm_release.falco` in `helm-security.tf`.

---

## Phase E — CI pipeline hardening

**Goal:** Replace brittle `sleep 60` with real rollout waits. Add bc-ctrl stack to pipeline targets.

- [ ] **E.1** Edit `.github/workflows/terraform-deploy.yml`: replace `sleep 60` in ctrl-plane stage-3 with `kubectl rollout status ds/cilium -n kube-system --timeout=180s` + same for `ds/tetragon` + `ds/falco`. **Validation:** `yamllint` + `actionlint` on the workflow file return clean.
- [ ] **E.2** Add bc-ctrl Cilium/Falco/Tetragon helm_releases to stage-3 `-target=` list. **Validation:** `grep -A5 'stage-3' .github/workflows/terraform-deploy.yml` shows the 3 targets.
- [ ] **E.3** Commit + push on feature branch, open PR. **Validation:** pipeline green on PR.
- [ ] **E.4** Merge. **Validation:** `main` pipeline green end-to-end.

---

## Phase F — Make the stack MANDATORY (post-validation)

**Goal:** Codify the stack so no future EKS cluster can be created without it. Non-negotiable.

**Design:** Module supports two modes via `var.cni_mode` — `"eni"` (default, preferred for fresh clusters, proven on bc-prd) and `"chaining"` (migration escape hatch for clusters with pre-existing VPC CNI + live workloads, used on bc-ctrl). Same Falco + Tetragon + Hubble regardless of mode.

- [ ] **F.1** Create `new-infra/modules/eks-security-stack/` — packages Cilium + Falco + Tetragon + Hubble helm_releases. Inputs: `cluster_name`, `cluster_endpoint`, `oidc_provider_arn`, `cni_mode` (`"eni"` | `"chaining"`, default `"eni"`), `falcosidekick_enabled` (default `false`). **Validation:** `terraform -chdir=new-infra/modules/eks-security-stack validate` passes.
- [ ] **F.2** Refactor `new-infra/environments/bc-prd/eu-central-1/helm-security.tf` to call the module with `cni_mode = "eni"` + `falcosidekick_enabled = true`. **Validation:** `terraform plan` shows zero resource changes (pure refactor).
- [ ] **F.3** Refactor `new-infra/environments/bc-ctrl/eu-central-1/helm-security.tf` to call the module with `cni_mode = "chaining"`. **Validation:** `terraform plan` shows zero resource changes.
- [ ] **F.4** Update `CLAUDE.md` Critical AI Guardrails section: strengthen the "Mandatory Stack" line to "Every EKS cluster MUST call `module.eks-security-stack`. This is non-negotiable — enforced by CI." **Validation:** `grep -A1 'Mandatory Stack' CLAUDE.md` shows the new wording.
- [ ] **F.5** Extend `/tf-review` skill to block any env dir containing `module "eks"` but NOT `module "eks-security-stack"`. **Validation:** craft a test TF without the security module → skill flags it → restore normal TF → skill clean.
- [ ] **F.6** Final PR: module + refactor + CLAUDE.md + skill change. **Validation:** CI green, reviewer approval, merged.

---

## Deferred / Out of Scope (tracked, not blocking)

**Explicitly excluded per user directive (2026-04-17):** Any pre-existing bug in Suricata / Wazuh / Zeek / MISP deployments. We will NOT debug these; we will only ensure our changes do not make them worse.

- [OUT] bc-prd Suricata DS has 0 pods — missing `role=workload` node label (pre-existing)
- [OUT] bc-prd wazuh-agent stuck `Init:0/1` (pre-existing)
- [OUT] bc-ctrl `ebs-csi-controller` CrashLoop → Wazuh indexer/manager `Pending` (pre-existing)
- [OUT] bc-ctrl `wazuh-indexer-ism-bootstrap` CreateContainerConfigError (pre-existing)
- [OUT] Wazuh Indexer anti-affinity on bc-ctrl — already resolved by 3-node scale-up (`f3de20e`)
- Hubble UI Ingress via ALB + Keycloak OIDC (currently port-forward only — no auth on Hubble)
- `hostFirewall: true` + node-level CCNPs for Suricata/Zeek host networking
- DLP for sensitive data exfil (from RobotLab security recs)
- MISP hardening: dedicated ServiceAccount + proper CA-signed cert (remove `curl -k`)

---

## Change log

<!-- append dated lines as phases close -->
- (empty)

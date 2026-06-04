You are planning the remaining implementation work for an XDR security platform
called UATMS (Ultra Advanced Threat Monitoring System) built on AWS eu-central-1
for Big Chemistry / Fontys University. This is a security monitoring repo — it does
not contain research workloads.

## Your job

Produce a complete, concrete implementation plan for all remaining phases. "Complete"
means: actual YAML snippets, actual Terraform diffs, actual commands — not high-level
descriptions. Every task must have a specific validation step that proves it worked. The development must be sub-agent driven, each subagent with clear instructions - you monitor everything.

## Read these files first, in this order

1. `CLAUDE.md` — full architecture, EC2/EKS inventory, data flow, file paths, guardrails
2. `SECURITY_STACK_ROLLOUT_PLAN.md` — the phase tracker (phases B.7 onward are undone)
3. `new-infra/docs/cilium-eks-security-planning.md` — full Cilium use-case analysis and
   multi-VPC architecture rationale (explains the WHY behind every phase)

Then read these specific files before writing each phase's artifacts:

- Phase D (CNP manifests): read `new-infra/k8s/wazuh-agent/daemonset.yaml`,
  `new-infra/k8s/suricata/daemonset.yaml`, `new-infra/k8s/zeek/daemonset.yaml`
  — you need the actual pod labels and namespace names to write correct
  CiliumNetworkPolicies
- Phase G (kube-proxy removal): read `new-infra/environments/bc-prd/eu-central-1/eks.tf`
  — check whether `kube-proxy` is in `cluster_addons` before writing the removal diff
- Phase F (module): read `new-infra/environments/bc-prd/eu-central-1/helm-security.tf`
  — you are refactoring this file into a module; you need to see its current structure
- Phase I (Hubble ingress): Keycloak is fully deployed in the `nomad-oasis` namespace. The plan must use Keycloak as the OIDC provider for Hubble UI ingress.

## Architecture facts (do not re-derive these)

- **bc-ctrl** (10.0.0.0/16): EC2-only, NO EKS. Wazuh all-in-one (t3.xlarge, 4.14.4),
  MISP 2.5 (t3.large), Shuffle SOAR (t3.large, Docker Compose), GitHub Runner (t3.small).
- **bc-prd** (10.30.0.0/16): EKS 1.35, 2×t3.medium. Security stack: Cilium 1.19.3 ENI
  mode + Hubble, Falco 8.0.2, Tetragon 1.6.1, External Secrets 0.10.7, Keycloak.
- **VPC Peering** (no Transit Gateway): bc-prd → bc-ctrl. Wazuh telemetry crosses this
  link on TCP 1514 — currently plaintext. WireGuard is the fix (Phase H).
- **All three sensor DaemonSets** (wazuh-agent, suricata, zeek) run `hostNetwork: true`.
  In Cilium ENI mode this means they are identified by NODE identity, not pod identity.
  CNPs for hostNetwork pods must use `fromEntities: ["host"]` for ingress and CIDR-based
  egress. Verify your CNP designs against Cilium 1.19 docs before finalizing.
- **Suricata and Zeek have 0 scheduled pods** right now. Root cause: missing
  `role=workload` node label. Phase D.0 is the fix (label nodes + add to eks.tf
  node group labels block so new nodes inherit it).
- **Tetragon TracingPolicy** (SIGKILL on nc/nmap) exists at
  `new-infra/k8s/tetragon/tracing-policy.yaml` but has NEVER been applied to the cluster.
  Phase D.8 applies it.
- **Cost ceiling:** ~$565/month baseline. Flag anything adding >$10/month.
- **Do NOT use:** Transit Gateway, Cluster Mesh, t3.small nodes, chaining mode CNI,
  `enable_cluster_creator_admin_permissions = true`.

## What is already done (do not re-plan these)

Phases 0, A complete. Phases B.1–B.6 complete (Terraform validated, not yet applied to
cluster). Phases C and E superseded. KMS drift fix done. All of this is crossed out in
the rollout plan.

## The remaining phases to plan (in dependency order)

**B.7–B.12** — Push current main to CI, apply Hubble UI + version-pinned stack to
bc-prd, validate all four components healthy. This unblocks everything else.

**D.0** — Apply `role=workload` node label live AND permanently in eks.tf. Unblocks
sensor scheduling.

**D.2–D.11** — Write and apply CiliumNetworkPolicies for wazuh-agent, suricata, zeek.
Apply Tetragon TracingPolicy. Validate with Hubble. Flip `policyEnforcementMode` from
`default` → `always`.

**G** — Remove kube-proxy addon, enable `kubeProxyReplacement=true` in Cilium.
(Can run in parallel with D once B is complete.)

**H** — Enable WireGuard node-to-node + node egress encryption. Encrypts the Wazuh
telemetry crossing VPC peering. Requires Phase D stable.

**I** — Hubble UI permanent ingress via internal ALB + OIDC. Can run in parallel with
D/G/H once B.9 is done.

**J** — Replace broad `0.0.0.0/0:443` egress in Suricata CNP with FQDN-specific rules
(`rules.emergingthreats.net` only). Requires Phase D.

**F** — `eks-security-stack` Terraform module packaging Cilium+Falco+Tetragon+
ExternalSecrets. Every future research VPC EKS cluster calls this module. Requires Phase
D stable. Before writing F.1, you must answer the 3 architecture questions below.

**K** — Host Firewall (deferred, needs scratch cluster validation first due to ENI mode
device interaction). Plan the scratch cluster test approach.

## 3 architecture questions that block Phase F

These must be answered (with a recommendation and rationale) before the module can be
designed correctly:

1. **Same AWS account or separate accounts for research VPCs?** Impacts: IRSA trust
   boundaries, Secrets Manager cross-account paths, CI OIDC role scoping.
2. **One repo or separate repos for research VPC CI?** Impacts: module source reference
   (`//modules/eks-security-stack` local vs. registry), who owns the security stack version.
3. **Nomad deployment pattern on EKS: DaemonSet or Deployment?** Impacts: which ports
   need to be in CNPs for the research cluster's workloads.

Give a concrete recommendation for each, with the security/operational tradeoff clearly
stated. These answers feed directly into the Phase F module variable surface.

## Output format

Structure the output as:

1. **Answers to the 3 architecture questions** (with recommendations)
2. **Phase-by-phase implementation plan** — for each phase:
   - Exact file to edit and the diff or YAML to add
   - Exact commands to run (copy-paste ready)
   - Exact validation command and expected output
   - Any rollback trigger (what output means "stop and revert")
3. **Updated dependency graph** showing the parallel tracks
4. **Risk register** — top 5 things most likely to fail and why

Do not summarize the plan at the end. End with the risk register.

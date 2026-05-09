# Session 2026-05-09 — NOMAD Oasis deployment attempt

End-of-session summary written before destroying the cluster. **NOMAD Oasis was NOT successfully deployed**; the platform converged most of the way but the final pod-readiness check timed out across multiple runs. Five distinct root causes were diagnosed and fixed in code; one is suspected but not yet validated against a fresh cluster.

## What was attempted

Deploy NOMAD Oasis (FAIRmat-NFDI Helm chart `default` v1.4.2) onto the existing bc-prd EKS cluster as a security-stack observability target — sized for testing only (1× t3.large dedicated node group, Minikube-tier values), not for real research workloads. Stack: nomad-app, nomad-worker, MongoDB, PostgreSQL, Elasticsearch, RabbitMQ, Temporal, plus EFS for shared NOMAD volumes (RWX) and gp3 EBS for databases.

## Code changes that landed (all on `main`)

| Commit | What |
|---|---|
| `f77b57c` | bc-prd TF: EBS+EFS CSI add-ons, EFS file system + StorageClass `efs-nomad-sc`, dedicated `nomad` node group, ALB controller release, 5 Secrets Manager shells, NOMAD Helm release, `nomad-values.yaml` |
| `ee5a06c` | k8s manifests: namespace, 5 ExternalSecrets, 7 CiliumNetworkPolicies, wazuh-agent log mount |
| `6f36a4d` | CI: GitHub Secrets → AWS Secrets Manager seed step, idempotent SHA-compare; pipeline reordering for cold-start |
| `c156c52` | Replaced em-dash `—` with `--` in EC2 SG description (AWS rejects non-ASCII for SG `GroupDescription`) |
| `ef4687b` | New CNPs for ebs-csi, efs-csi, alb-controller (Cilium policyEnforcementMode=always was deny-all-egress for new addon controller pods) |
| `ffa77e9` | CI: apply system netpols early (pre-Stage-1) so addon pods have egress before EKS addon `wait_for_active` ticks |
| `469839d` | Broaden EBS CSI CNP selector from `app=ebs-csi-controller` → `app.kubernetes.io/name=aws-ebs-csi-driver` so it covers BOTH the controller Deployment AND the node DaemonSet; add IMDS allow `169.254.169.254/32:80`; make pre-Stage-1 netpol apply self-config kubectl |
| `bce3e45` | Drop stale STS `toCIDRSet` rules (10.30.10.209/32, 10.30.11.123/32 — those ENIs no longer exist after VPC rebuild). Rely on `toEntities: world:443` fallback which already routes via fck-nat. Updates CLAUDE.md "Cilium ENI Mode" |
| `f36b50d` | gp3 StorageClass + ESO toleration for `dedicated=nomad:NoSchedule` (workload pool t3.medium × 2 was at pod limit; ESO needed to spill to nomad node) |
| `56a6276` | Add `toEntities: cluster` alongside `kube-apiserver` to all 9 system netpols. Cilium `kubeProxyReplacement=true` rewrites ClusterIP via BPF LB before policy eval; backend ENI IPs have `remote-node` identity, NOT `kube-apiserver`, so the original rule never matched. EBS CSI worked accidentally (its EC2 VPC-endpoint CIDRs happened to match the API server backend IPs in this cluster) |
| `72701c1` | CI: pipeline `-target=` lists were missing `kubernetes_storage_class.gp3`, `aws_iam_role.alb_controller`, `aws_iam_role_policy.alb_controller`, `helm_release.aws_load_balancer_controller`. Resources not in any target list are silently skipped by targeted apply. Added rule comment |
| `d8362e8` | ESO IAM: add `kms:Decrypt` + `kms:DescribeKey` on `module.eks.kms_key_arn` with `kms:ViaService = secretsmanager.eu-central-1.amazonaws.com` condition. SM secrets are KMS-encrypted with the EKS key; `GetSecretValue` was failing with `AccessDeniedException: Access to KMS is not allowed`. **This was the final root cause identified — never validated against a fresh cluster.** |

## Run history

| Run | Result | Root cause(s) at the time |
|---|---|---|
| 25606334520 | failure | em-dash in SG description; EBS CSI addon stuck CREATING because controller pods CrashLoopBackOff (no CNP allowed STS egress) |
| 25607548379 | failure | netpol fix landed but pre-Stage-1 apply step had no kubeconfig configured |
| 25608072993 | failure | (teammate's docs-only commit, unrelated) |
| 25608479913 | failure | NOMAD readiness wait timed out: gp3 SC missing (not in `-target=` list); ESO ClusterSecretStore stale `ValidationFailed` (auth couldn't reach API server via ClusterIP); ESO new pod could not schedule (workload pool at pod limit, no toleration for nomad node) |
| 25609075526 | cancelled | gp3 still missing; ESO API-server unreachable still |
| 25609669723 | failure | first run with the `toEntities: cluster` netpol fix; revealed final blocker: `AccessDeniedException: Access to KMS is not allowed` (ESO IAM had SM read but not KMS Decrypt) |
| 25610096838 | cancelled | KMS fix pushed but run got stuck on `kubectl wait` again (5m+ at the time of cancellation) — not yet known if KMS fix actually worked because the secrets layer hadn't fully retried |

## Distinct root causes diagnosed today

1. **Em-dash in EC2 SG description**. AWS rejects non-ASCII for `GroupDescription`. Fixed.
2. **Cilium policyEnforcementMode=always deny-by-default**. New addon pods (EBS/EFS CSI, ALB controller) had no CNP. Same precedent as ESO had at install. Fixed by adding 3 system netpols.
3. **Pre-Stage-1 apply step had no kubeconfig**. Step ran before the dedicated kubectl-config step. Fixed by self-running `aws eks update-kubeconfig` in the step.
4. **EBS CSI selector mismatch**. Original CNP matched only `app=ebs-csi-controller`; the node DaemonSet has `app=ebs-csi-node`. Switched to `app.kubernetes.io/name=aws-ebs-csi-driver` to cover both. Also added IMDS link-local egress.
5. **Stale STS VPC endpoint IPs in `toCIDRSet`**. Cluster/VPC was rebuilt; ENI IPs `10.30.10.209/.123` no longer existed. Dropped the CIDR rule entirely; `toEntities: world:443` already covers STS via fck-nat.
6. **Missing `gp3` StorageClass**. Chart references `gp3` for Mongo/PG/ES; only `gp2` (legacy in-tree) and `efs-nomad-sc` existed. Added `kubernetes_storage_class.gp3` resource.
7. **Pod limit on workload pool exhausted**. t3.medium × 2 hit the 17-pods-per-node limit after NOMAD deploy. ESO rolled-restarted pod went Pending. Added `dedicated=nomad:NoSchedule` toleration to ESO Helm values.
8. **Stage 1 `-target=` list incomplete**. `kubernetes_storage_class.gp3` and ALB controller IAM resources were declared but not targeted, silently skipped by `terraform apply -target`. Added them + a comment-rule for future maintenance.
9. **Cilium `toEntities: kube-apiserver` doesn't match BPF-rewritten ClusterIP**. With `kubeProxyReplacement=true`, Cilium's BPF LB rewrites `172.20.0.1:443` to API server backend ENI IPs *before* policy evaluation. Those backend ENIs have `remote-node` identity, not `reserved:kube-apiserver`. Added `cluster` to `toEntities` across all 9 system netpols. EBS CSI was working by accident (its EC2 VPC endpoint CIDRs happened to be the same IPs as the API server backend ENIs in this cluster).
10. **ESO IAM had SM read but not KMS Decrypt**. SM secrets are encrypted with the EKS cluster KMS key. ClusterSecretStore validation succeeded (no KMS path) but every `GetSecretValue` failed with `AccessDeniedException: Access to KMS is not allowed`. Added `kms:Decrypt` + `kms:DescribeKey` on `module.eks.kms_key_arn` with `kms:ViaService=secretsmanager.eu-central-1.amazonaws.com` condition.

## What's unconfirmed

The KMS fix (`d8362e8`) was pushed at the end of the day. The triggered run was cancelled while still on `kubectl wait` after 5 min — not a long enough window to know if the secrets actually synced once the IAM change applied. **It is plausible but unverified that this was the final blocker.** Next session, if a fresh deploy still fails after the KMS change is in state, suspect a different KMS layer (e.g., the secrets weren't actually encrypted with the cluster key but with a different account-level key) — confirm by `aws secretsmanager describe-secret --secret-id bc/nomad-oasis/api --query KmsKeyId` and matching against `module.eks.kms_key_arn`.

## What was deferred / out of scope

- Pre-existing `falco-sjdv2` CrashLoopBackOff on `ip-10-30-10-130` (3h+ old, not related to NOMAD work). Pipeline's `Verify security stack` rollout-status passed despite this — kubernetes considered 1/2 pods ready good enough.
- Pre-existing `tetragon-operator`, `hubble-relay`, `hubble-ui` CrashLoopBackOff (also pre-NOMAD).
- ALB ingress for NOMAD — deferred until ACM cert + public Route53 zone exist (Phase I).

## Cost trajectory (uncommitted changes for next session)

Plan was: ~$84/mo addition for NOMAD = $649/mo total baseline (down from t3.xlarge ×2 pre-resize estimate of ~$264/mo). Never validated under load because deploy never completed.

## State of the cluster at end of session (before destroy)

- 2 workload nodes (t3.medium), 1 nomad node (t3.large) — all Ready
- EBS CSI + EFS CSI addons: ACTIVE
- Cilium, Falco, Tetragon, External Secrets: deployed
- NOMAD Helm release: deployed but pods broken (app/worker `CreateContainerConfigError`, mongo/postgres/ES Pending)
- 5 Secrets Manager shells exist with values seeded by CI from GitHub repo secrets (verified manually via `aws secretsmanager get-secret-value`)
- gp3 StorageClass: exists (created by Stage 1 once `-target=` was fixed)

## Action items for next session

1. **Verify KMS fix landed**: `aws iam get-role-policy --role-name bc-uatms-prd-external-secrets --policy-name <name>` should show `kms:Decrypt` + `kms:DescribeKey` on the EKS key with the ViaService condition.
2. **Validate against a fresh cluster**: `terraform destroy` + apply via CI from cold. The KMS fix lands in Stage 2; if the very first apply succeeds the loop is closed.
3. **Take a hard look at falco/hubble/tetragon-operator pre-existing CrashLoops**. They're noise during NOMAD debugging but are real platform issues.
4. **Decide on STS endpoint optimization**. CIDR rule was dropped in favor of `toEntities: world:443`. If you want the VPC-internal short-circuit back, the recipe is in the updated CLAUDE.md "Cilium ENI Mode" section.

## Two durable engineering lessons

1. **`toEntities: kube-apiserver` is NOT a complete K8s API allow rule when Cilium kubeProxyReplacement is on**. Always pair it with `cluster`.
2. **A KMS-encrypted Secrets Manager secret requires `kms:Decrypt` on the encrypting key in addition to `secretsmanager:GetSecretValue` on the secret ARN**. The IRSA pattern from the official docs typically shows both; ours showed only the SM permission for a long time.

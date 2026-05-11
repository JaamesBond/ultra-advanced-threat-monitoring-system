# Session 2026-05-11/12 — Self-managed Keycloak migration + full cold-start hardening

End-of-session summary written before destroying the cluster. **Cold-start path is now fully self-healing and validated end-to-end.** Local Keycloak deployment works inside the cluster, but **browser-side OAuth login does NOT work over the dev-path (HTTP)** because modern Keycloak (24+) requires HTTPS for session cookies (`SameSite=None` + `Secure`). Backend OIDC discovery + token validation works fine.

## TL;DR for the next dev

- The pipeline runs from cold-start to green-green end-to-end. ~22 commits today consolidated this. Don't break it.
- NOMAD Oasis is running inside the cluster and the GUI is reachable via port-forward.
- The realm `nomad-oasis` is auto-imported with a `testuser`/`testpass123` account. Keycloak's discovery doc emits `issuer: http://localhost/auth/realms/nomad-oasis` and is reachable from NOMAD backend.
- **Browser login fails at the form-submit step** with "Cookie not found". This is the boundary of the dev-path approach. Fix requires either (a) production path with real HTTPS or (b) a Keycloak SPI customization to disable `SameSite=None` defaults (Keycloak 24 doesn't expose this cleanly).
- Cluster was destroyed end-of-day per on-demand teardown pattern.

## What was attempted

Migrate NOMAD Oasis authentication from the public `nomad-lab.eu` federated Keycloak to a self-managed Keycloak running inside bc-prd EKS. Constraints chosen: dev-path (no public DNS, no Ingress, no TLS) — access only via existing `kubectl port-forward` + AWS SSM port-forwarding to a local browser.

The migration uncovered a long chain of cold-start race conditions and missing IAM/network/config bits that we hardened systematically. The Keycloak deploy itself succeeded; the browser auth flow turned out to be incompatible with pure HTTP.

## Code changes that landed today (all on `main`)

Listed in chronological order. Each was diagnosed live against the running cluster before committing.

### Cold-start hardening (independent of Keycloak)

| Commit | What |
|---|---|
| `e63bef1` | bc-prd state-health guard distinguishes Case 2 (true cold-start, empty AWS) from Case 3 (drift). Previously failed loud on both. |
| `7d3c742` | `aws_efs_mount_target` `for_each(toset(subnet_ids))` → `count = 2`. for_each requires plan-time-known keys; subnet IDs are apply-time-unknown on cold-start. |
| `1385331` | All `bc/nomad-oasis/*` Secrets Manager secrets: `recovery_window_in_days = 0` + `prevent_destroy = false`. Default 7-day soft-delete blocks name re-use on next cold-start. |
| `872a674` | Stage 2a CRD wait drops `tracingpolicies.cilium.io` (Tetragon CRD, installed in Stage 2b). Comment above the wait already said this; code didn't match. |
| `ab70af1` | System network policies applied after Stage 2b (not before). `policyEnforcementMode=default` means CNPs don't need to exist before Helm releases. |
| `8e5c17c` | Shared `ClusterSecretStore` extracted from `k8s/suricata/external-secrets.yaml` to `k8s/system-secretstore/`. NOMAD's ExternalSecrets at Stage 2c need it; suricata kustomize only applied at Stage 3. |
| `9abf683` | Cilium operator IRSA role + inline EC2 ENI policy. Operator pod was using IMDS → node role which lacks `ec2:AssignPrivateIpAddresses`. Result: pod IPs not registered on any AWS ENI → return traffic black-holed. |
| `5f5fd62` | Cilium IRSA Helm value path correction: `operator.serviceAccount.annotations` → `serviceAccounts.operator.annotations`. Wrong path was silently ignored. |
| `1ddeae4` | Pipeline auto-bounces kube-system/ESO/Temporal pods after each Helm stage so they pick up fresh IPs + DNS resolver state from the now-healthy Cilium operator. |
| `f54a360` | ALB controller `enableServiceMutatorWebhook: false` + workflow forces `kubectl rollout restart deploy/cilium-operator` after Cilium Helm install. Operator pods don't auto-restart on SA annotation changes (warm-update path). |
| `2ec57d5` | Cilium operator: explicit `AWS_REGION=eu-central-1` env var + `cluster.name=bc-uatms-prd-eks`. Without AWS_REGION the SDK falls back to IMDS lookup or us-east-1 and EC2 calls time out. |
| `3fe6774` | Added `ec2:DescribeRouteTables` to the cilium-operator IAM policy. Missing from the initial draft. |
| `d626545` | Heal kube-system step uses `kubectl wait --for=condition=available` instead of `kubectl rollout status`. The latter blocks on old-pod termination (~5-10 min on EBS CSI controller's graceful shutdown). |

### Keycloak-specific

| Commit | What |
|---|---|
| `fbd3d09` | Initial Keycloak migration: enable keycloakx 7.1.9 sub-chart, realm-import ConfigMap, DB init Job, nginx proxy `/auth/` overlay, three new pipeline steps (DB init, proxy patch, hostname verify). |
| `f8cbbd1` | Proxy overlay rewritten to match the chart-generated nginx.conf byte-for-byte (`server {}` only, no `http {}` wrapper). The initial draft would have CrashLooped nginx. |
| `a43dbcb` | ESO cert-controller rollout wait is best-effort. The cert-controller's readiness probe never passes in this chart version. |
| `1afba14` | ALB controller `webhookConfig.failurePolicy=Ignore` (only affects mpod webhook — chart hardcodes Fail for mservice). Superseded by `f54a360`. |
| `793ae66` | Keycloak probes converted to YAML block-scalar strings (chart uses `tpl` and requires strings, not maps). Removed `service:` override (chart defaults align with everything else). Added `http.relativePath: /auth`. |
| `8ca1688` | DB init Job psql script: pass `KC_DB_PASSWORD` as `-v kc_db_password=…` so the `:'kc_db_password'` substitution works. Use `quote_literal()` for SQL-injection-safe interpolation. |
| `9c41a39` | Service name correction: `nomad-oasis-keycloak` → `nomad-oasis-keycloak-http` everywhere (nginx, NOMAD `server_url`, Step C verification curl). Also applies realm-import ConfigMap in Stage 2c (before Stage 2d Helm), so the Keycloak StatefulSet can mount it. |
| `2c29d4d` | Keycloak `cache.stack: kubernetes`. Chart hardcodes `KC_CACHE_STACK=jdbc-ping` when DB is external; Keycloak 24 rejects `jdbc-ping`. Also Temporal heal uses `condition=available` instead of `rollout status`. |
| `400bf02` | Step B (nginx overlay apply + proxy restart) uses `condition=available`. The proxy pod can take 3-6 min to get a Cilium IP on cold-start; rollout-status was timing out at 5 min. |
| `c4cf79e` | Keycloak probe paths corrected: `/health/started`, `/health/ready`, `/health/live` (not `/auth/health`). Superseded by `76e70a4`. |
| `76e70a4` | Keycloak probes switched to plain TCP socket on port `http`. Keycloak 24 does NOT have a separate management interface (introduced in 25); the chart's `http-internal` port has no listener. Workflow Step C also auto-rolls a stuck Keycloak pod when its `controller-revision-hash` lags the StatefulSet's `updateRevision`. |
| `a79c073` | `KC_HOSTNAME=localhost` (no scheme). Setting `http://localhost` produced `issuer: http://http//localhost/...` (double http) because Keycloak prepends its own scheme. |
| `fc1efdc` | Added `nomad-proxy-netpol` egress for keycloak:8080. nginx `/auth/` proxy_pass was being silently dropped by Cilium policy. |
| `d6b779d` | Removed `KC_PROXY=edge`. It tells Keycloak the request was HTTPS at the edge, so cookies are set with the `Secure` flag, and the browser drops them on HTTP. Did NOT fully fix browser login (see Open Issues). |

## What works end-to-end

- **Cold-start from empty AWS state**: pipeline reaches NOMAD GUI online with zero manual steps. ~22 minute total runtime.
- **Keycloak StatefulSet**: starts cleanly, imports `nomad-oasis` realm, serves `/auth/*` on port 8080.
- **Keycloak OIDC discovery**: `http://localhost/auth/realms/nomad-oasis/.well-known/openid-configuration` returns valid JSON with `issuer: http://localhost/auth/realms/nomad-oasis`, `token_endpoint: http://nomad-oasis-keycloak-http/auth/...` (backchannel-dynamic).
- **NOMAD ↔ Keycloak backend**: NOMAD app pod can call Keycloak admin REST API. Confirmed by checking app pod logs (no OIDC errors).
- **NOMAD GUI**: reachable at `http://localhost/nomad-oasis/gui/` through the SSM port-forward + kubectl port-forward chain.
- **Anonymous browsing**: works fully — About page, public data browsing.
- **All 12 NOMAD pods + Keycloak Running 1/1** on a stable cluster, including post-pipeline-completion.

## What does NOT work (the open issue)

**Browser-side OAuth login completes the first GET but fails the form-submit POST with:**

```
We are sorry...
Cookie not found. Please make sure cookies are enabled in your browser.
```

HTTP 400 from `/auth/realms/nomad-oasis/login-actions/authenticate`. Cookies ARE enabled — Keycloak is setting them with `SameSite=None` (Keycloak 24+ default for cross-site auth flows). The browser silently drops `SameSite=None` cookies that don't also have `Secure`, and `Secure` requires HTTPS. Our dev-path is HTTP all the way (browser → SSM port-forward → nginx → Keycloak).

### Things that were tried and didn't fix it

1. `KC_PROXY=edge` removed (was forcing Secure flag explicitly).
2. `KC_HOSTNAME` variations (full URL, hostname-only, with `KC_HOSTNAME_STRICT*=false`).
3. Browser tested in both regular and private/incognito sessions.
4. Adding `127.0.0.1 nomad-oasis-keycloak-http` to `/etc/hosts` (orthogonal — works for some flows, irrelevant for the cookie issue).

### Things NOT yet tried (potential paths forward)

1. **Production path (recommended).** ALB Ingress + ACM cert + Route53 zone you control. Browser sees real HTTPS; Keycloak's `SameSite=None; Secure` cookies work natively. Eliminates the entire class of bug. Estimated ~1-2h to wire if you have a domain ready. ALB ~$16/month, ACM free, Route53 $0.50/month.
2. **Keycloak SPI customization** to disable `SameSite=None` defaults. Keycloak 24 doesn't expose this via env/CLI cleanly. Would need a custom CookieSetter SPI or a downstream Keycloak fork. Not recommended.
3. **`KC_HOSTNAME_STRICT_BACKCHANNEL=false`** (deprecated alias). Not tried because of confusing docs; might have an effect on cookie domain mismatch.
4. **Try a different Keycloak version** (e.g., 22.x) that defaults to `SameSite=Lax`. Risky — drift from current upstream.

## Architecture decisions and rationale

### Why dev-path was chosen

The user explicitly opted out of public DNS / Ingress / TLS for the first round of Keycloak migration. The rationale was to keep operational scope small and avoid domain decisions until later. We documented this trade-off but underestimated the modern Keycloak cookie defaults, which boxed us out of browser login on HTTP.

### Why local Keycloak vs federated

Original setup federated to `nomad-lab.eu/fairdi/keycloak/auth/`. Migration goal was self-managed identity so the platform is self-contained and survives nomad-lab.eu outages or policy changes. `nomad.config.oasis.uses_central_user_management` was flipped to `false`.

### Cilium ENI mode is structurally fragile on warm updates

The biggest single class of bugs today was Cilium operator IRSA not taking effect on warm updates (SA annotation change does not restart pods). The workflow now explicitly bounces cilium-operator after every Cilium Helm release. **Do not remove this step** without understanding what it covers.

## Cluster state at end-of-session

- bc-prd EKS: 12 NOMAD pods Running 1/1, Keycloak 1/1, security stack 1/1.
- bc-ctrl: Wazuh, MISP, Shuffle EC2s running.
- Pipeline run: green end-to-end.
- Cluster destroyed at end-of-day per on-demand teardown pattern (next dev cold-starts from empty AWS state).

## Recommended next session goals

1. **Decide on production path or accept dev-path login limitation.** If production, choose a domain. If accepting, document that login flow requires production-path migration and consider whether NOMAD anonymous browsing is sufficient for current use cases.
2. **If pursuing production path:** ALB Ingress + ACM cert + Route53. Update `KC_HOSTNAME` to the real hostname (e.g., `keycloak.bc-prd.your-domain.com`), drop the nginx `/auth/` overlay (Keycloak gets its own Ingress), revert `nomad.config.keycloak.server_url` to the public Keycloak URL.
3. **The hostAliases approach** the original Plan considered was avoided because `KC_HOSTNAME_BACKCHANNEL_DYNAMIC=true` solved the dual-URL problem for backend/frontend split. Keep that intact.
4. **Realm-import JSON** at `new-infra/k8s/nomad-oasis/keycloak-realm-import-configmap.yaml` is the source of truth. Any manual realm changes made via the Keycloak admin UI will be overwritten on next cold-start. Bake new users/clients into this JSON.

## Run history (today's pipeline runs)

Run IDs increased from `25671054584` through `25697958683`. Each failure surfaced exactly one root cause that was fixed in code. By the final run the pipeline self-heals every cold-start condition encountered today.

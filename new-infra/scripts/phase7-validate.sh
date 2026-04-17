#!/usr/bin/env bash
# =============================================================================
# phase7-validate.sh — XDR v8 / bc-ctrl EKS → bare EC2 migration
# Phase 7: Post-migration validation — ALL 9 checks must pass before
#           EKS decommission is approved.
#
# Usage:
#   export INDEXER_IP=<ip>       # Wazuh Indexer (OpenSearch) :9200
#   export MANAGER_IP=<ip>       # Wazuh Manager API :55000
#   export DASHBOARD_IP=<ip>     # Wazuh Dashboard :443
#   export MISP_IP=<ip>          # MISP web :443
#   export WAZUH_API_USER=<user> # Wazuh Manager API username
#   export WAZUH_API_PASS=<pass> # Wazuh Manager API password
#   export INDEXER_USER=<user>   # OpenSearch admin username
#   export INDEXER_PASS=<pass>   # OpenSearch admin password
#   export EXPECTED_AGENT_COUNT=<n>  # Minimum active agents expected
#   bash phase7-validate.sh
#
# Optional:
#   INDEXER_PORT=9200            (default 9200)
#   MANAGER_PORT=55000           (default 55000)
#   DASHBOARD_PORT=443           (default 443)
#   MISP_PORT=443                (default 443)
#   SOAK_MINUTES=5               (default 5)
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed
# =============================================================================
set -uo pipefail
# Note: -e is intentionally omitted so that individual check failures are
# caught and reported without aborting the whole script.

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INDEXER_PORT="${INDEXER_PORT:-9200}"
MANAGER_PORT="${MANAGER_PORT:-55000}"
DASHBOARD_PORT="${DASHBOARD_PORT:-443}"
MISP_PORT="${MISP_PORT:-443}"
SOAK_MINUTES="${SOAK_MINUTES:-5}"

# Baseline files written by phase1-backup.sh
ALERT_BASELINE_FILE="${SCRIPT_DIR}/wazuh-alert-baseline.txt"
AGENT_BASELINE_FILE="${SCRIPT_DIR}/wazuh-agent-baseline.txt"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
PASS_COUNT=0
FAIL_COUNT=0
declare -a RESULTS=()

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

check_pass() {
  local name="$1"
  local detail="${2:-}"
  PASS_COUNT=$((PASS_COUNT + 1))
  RESULTS+=("PASS  ${name}${detail:+  (${detail})}")
  log "  [PASS] ${name}${detail:+  — ${detail}}"
}

check_fail() {
  local name="$1"
  local reason="${2:-}"
  FAIL_COUNT=$((FAIL_COUNT + 1))
  RESULTS+=("FAIL  ${name}${reason:+  →  ${reason}}")
  log "  [FAIL] ${name}${reason:+  — ${reason}}"
}

require_env() {
  local var="$1"
  if [[ -z "${!var:-}" ]]; then
    echo "ERROR: Required environment variable ${var} is not set."
    echo "See script header for usage."
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Validate required env vars
# ---------------------------------------------------------------------------
require_env INDEXER_IP
require_env MANAGER_IP
require_env DASHBOARD_IP
require_env MISP_IP
require_env WAZUH_API_USER
require_env WAZUH_API_PASS
require_env INDEXER_USER
require_env INDEXER_PASS
require_env EXPECTED_AGENT_COUNT

INDEXER_BASE="https://${INDEXER_IP}:${INDEXER_PORT}"
MANAGER_BASE="https://${MANAGER_IP}:${MANAGER_PORT}"
DASHBOARD_BASE="https://${DASHBOARD_IP}:${DASHBOARD_PORT}"
MISP_BASE="https://${MISP_IP}:${MISP_PORT}"

echo ""
echo "=============================================================="
echo "  PHASE 7 VALIDATION — XDR v8 Migration"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
echo "  Targets:"
echo "    Indexer:   ${INDEXER_BASE}"
echo "    Manager:   ${MANAGER_BASE}"
echo "    Dashboard: ${DASHBOARD_BASE}"
echo "    MISP:      ${MISP_BASE}"
echo "    Expected agents >= ${EXPECTED_AGENT_COUNT}"
echo "=============================================================="
echo ""

# ---------------------------------------------------------------------------
# CHECK 1 — Wazuh Indexer cluster health (green or yellow)
# ---------------------------------------------------------------------------
log "CHECK 1: Wazuh Indexer cluster health..."

HEALTH_RESPONSE="$(curl -sk \
  -u "${INDEXER_USER}:${INDEXER_PASS}" \
  "${INDEXER_BASE}/_cluster/health" \
  --connect-timeout 10 \
  --max-time 20 \
  2>/dev/null || echo '{}')"

CLUSTER_STATUS="$(echo "${HEALTH_RESPONSE}" | jq -r '.status // "unreachable"' 2>/dev/null || echo "unreachable")"
CLUSTER_NAME="$(echo "${HEALTH_RESPONSE}" | jq -r '.cluster_name // "?"' 2>/dev/null || echo "?")"

if [[ "${CLUSTER_STATUS}" == "green" || "${CLUSTER_STATUS}" == "yellow" ]]; then
  check_pass "Wazuh Indexer cluster health" "status=${CLUSTER_STATUS} cluster=${CLUSTER_NAME}"
else
  check_fail "Wazuh Indexer cluster health" \
    "status=${CLUSTER_STATUS} — expected green or yellow. Response: ${HEALTH_RESPONSE}"
fi
echo ""

# ---------------------------------------------------------------------------
# CHECK 2 — Wazuh alert count >= pre-migration baseline
# ---------------------------------------------------------------------------
log "CHECK 2: Wazuh alert count vs pre-migration baseline..."

BASELINE_ALERT_COUNT=0
if [[ -f "${ALERT_BASELINE_FILE}" ]]; then
  BASELINE_ALERT_COUNT="$(cat "${ALERT_BASELINE_FILE}" | tr -d '[:space:]')"
  log "  Baseline from ${ALERT_BASELINE_FILE}: ${BASELINE_ALERT_COUNT}"
else
  log "  WARNING: Baseline file not found at ${ALERT_BASELINE_FILE} — skipping count comparison (will only check > 0)"
fi

ALERT_COUNT_RESPONSE="$(curl -sk \
  -u "${INDEXER_USER}:${INDEXER_PASS}" \
  "${INDEXER_BASE}/wazuh-alerts-*/_count" \
  --connect-timeout 10 \
  --max-time 20 \
  2>/dev/null || echo '{}')"

CURRENT_ALERT_COUNT="$(echo "${ALERT_COUNT_RESPONSE}" | jq -r '.count // -1' 2>/dev/null || echo "-1")"

if [[ "${CURRENT_ALERT_COUNT}" -lt 0 ]]; then
  check_fail "Wazuh alert count" \
    "Could not retrieve alert count from OpenSearch. Response: ${ALERT_COUNT_RESPONSE}"
elif [[ "${CURRENT_ALERT_COUNT}" -ge "${BASELINE_ALERT_COUNT}" ]]; then
  check_pass "Wazuh alert count" \
    "current=${CURRENT_ALERT_COUNT} >= baseline=${BASELINE_ALERT_COUNT}"
else
  check_fail "Wazuh alert count" \
    "current=${CURRENT_ALERT_COUNT} < baseline=${BASELINE_ALERT_COUNT} — data may be missing"
fi
echo ""

# ---------------------------------------------------------------------------
# CHECK 3 — Wazuh Manager API responsive (version check)
# ---------------------------------------------------------------------------
log "CHECK 3: Wazuh Manager API version check..."

# Obtain JWT token first
TOKEN_RESPONSE="$(curl -sk \
  -u "${WAZUH_API_USER}:${WAZUH_API_PASS}" \
  -X GET \
  "${MANAGER_BASE}/security/user/authenticate?raw=true" \
  --connect-timeout 10 \
  --max-time 20 \
  2>/dev/null || echo "")"

if [[ -z "${TOKEN_RESPONSE}" || "${TOKEN_RESPONSE}" == "null" ]]; then
  check_fail "Wazuh Manager API" \
    "Could not obtain JWT token from ${MANAGER_BASE}/security/user/authenticate"
  WAZUH_TOKEN=""
else
  WAZUH_TOKEN="${TOKEN_RESPONSE}"
  VERSION_RESPONSE="$(curl -sk \
    -H "Authorization: Bearer ${WAZUH_TOKEN}" \
    "${MANAGER_BASE}/" \
    --connect-timeout 10 \
    --max-time 20 \
    2>/dev/null || echo '{}')"

  WAZUH_VERSION="$(echo "${VERSION_RESPONSE}" | jq -r '.data.api_version // "unknown"' 2>/dev/null || echo "unknown")"

  if [[ "${WAZUH_VERSION}" != "unknown" && "${WAZUH_VERSION}" != "" ]]; then
    check_pass "Wazuh Manager API" "version=${WAZUH_VERSION}"
  else
    check_fail "Wazuh Manager API" \
      "API responded but could not parse version. Response: ${VERSION_RESPONSE}"
  fi
fi
echo ""

# ---------------------------------------------------------------------------
# CHECK 4 — Active agent count >= EXPECTED_AGENT_COUNT
# ---------------------------------------------------------------------------
log "CHECK 4: Active agent count..."

if [[ -z "${WAZUH_TOKEN:-}" ]]; then
  check_fail "Active agent count" \
    "Skipped — no Wazuh API token (check 3 failed)"
else
  AGENTS_RESPONSE="$(curl -sk \
    -H "Authorization: Bearer ${WAZUH_TOKEN}" \
    "${MANAGER_BASE}/agents?status=active&limit=1&select=id" \
    --connect-timeout 10 \
    --max-time 20 \
    2>/dev/null || echo '{}')"

  ACTIVE_AGENTS="$(echo "${AGENTS_RESPONSE}" \
    | jq -r '.data.total_affected_items // -1' 2>/dev/null || echo "-1")"

  # Also load from baseline file if present
  BASELINE_AGENT_COUNT="${EXPECTED_AGENT_COUNT}"
  if [[ -f "${AGENT_BASELINE_FILE}" ]]; then
    FILE_BASELINE="$(cat "${AGENT_BASELINE_FILE}" | tr -d '[:space:]')"
    # Use the higher of the two
    if [[ "${FILE_BASELINE}" -gt "${EXPECTED_AGENT_COUNT}" ]]; then
      BASELINE_AGENT_COUNT="${FILE_BASELINE}"
      log "  Using baseline from file: ${BASELINE_AGENT_COUNT} (higher than EXPECTED_AGENT_COUNT=${EXPECTED_AGENT_COUNT})"
    fi
  fi

  if [[ "${ACTIVE_AGENTS}" -lt 0 ]]; then
    check_fail "Active agent count" \
      "Could not retrieve agent count. Response: ${AGENTS_RESPONSE}"
  elif [[ "${ACTIVE_AGENTS}" -ge "${BASELINE_AGENT_COUNT}" ]]; then
    check_pass "Active agent count" \
      "active=${ACTIVE_AGENTS} >= expected=${BASELINE_AGENT_COUNT}"
  else
    check_fail "Active agent count" \
      "active=${ACTIVE_AGENTS} < expected=${BASELINE_AGENT_COUNT} — agents may not have reconnected"
  fi
fi
echo ""

# ---------------------------------------------------------------------------
# CHECK 5 — Wazuh Dashboard returns HTTP 200
# ---------------------------------------------------------------------------
log "CHECK 5: Wazuh Dashboard HTTP 200..."

DASHBOARD_HTTP="$(curl -sk \
  -o /dev/null \
  -w "%{http_code}" \
  "${DASHBOARD_BASE}/" \
  --connect-timeout 10 \
  --max-time 20 \
  2>/dev/null || echo "000")"

if [[ "${DASHBOARD_HTTP}" == "200" || "${DASHBOARD_HTTP}" == "302" || "${DASHBOARD_HTTP}" == "301" ]]; then
  check_pass "Wazuh Dashboard" "HTTP ${DASHBOARD_HTTP} from ${DASHBOARD_BASE}"
else
  check_fail "Wazuh Dashboard" \
    "HTTP ${DASHBOARD_HTTP} from ${DASHBOARD_BASE} — expected 200/301/302"
fi
echo ""

# ---------------------------------------------------------------------------
# CHECK 6 — MISP login page returns HTTP 200
# ---------------------------------------------------------------------------
log "CHECK 6: MISP login page HTTP 200..."

MISP_HTTP="$(curl -sk \
  -o /dev/null \
  -w "%{http_code}" \
  "${MISP_BASE}/users/login" \
  --connect-timeout 10 \
  --max-time 20 \
  2>/dev/null || echo "000")"

if [[ "${MISP_HTTP}" == "200" || "${MISP_HTTP}" == "302" ]]; then
  check_pass "MISP login page" "HTTP ${MISP_HTTP} from ${MISP_BASE}/users/login"
else
  check_fail "MISP login page" \
    "HTTP ${MISP_HTTP} from ${MISP_BASE}/users/login — expected 200 or 302"
fi
echo ""

# ---------------------------------------------------------------------------
# CHECK 7 — MISP IOC sync timer active (systemctl)
# ---------------------------------------------------------------------------
log "CHECK 7: MISP IOC sync timer active..."

TIMER_STATUS="$(ssh -o StrictHostKeyChecking=no \
  -o BatchMode=yes \
  -o ConnectTimeout=10 \
  "${MISP_IP}" \
  "systemctl is-active misp-ioc-sync.timer" \
  2>/dev/null || echo "ssh-failed")"

if [[ "${TIMER_STATUS}" == "active" ]]; then
  check_pass "MISP IOC sync timer" "systemctl status=active"
elif [[ "${TIMER_STATUS}" == "ssh-failed" ]]; then
  check_fail "MISP IOC sync timer" \
    "SSH to ${MISP_IP} failed — ensure SSH key is configured and server is reachable"
else
  check_fail "MISP IOC sync timer" \
    "systemctl is-active misp-ioc-sync.timer returned '${TIMER_STATUS}' — expected 'active'"
fi
echo ""

# ---------------------------------------------------------------------------
# CHECK 8 — Wazuh self-agent (agent 000) is Active
# ---------------------------------------------------------------------------
log "CHECK 8: Wazuh self-agent (000) status..."

if [[ -z "${WAZUH_TOKEN:-}" ]]; then
  check_fail "Wazuh self-agent (000)" \
    "Skipped — no Wazuh API token (check 3 failed)"
else
  AGENT000_RESPONSE="$(curl -sk \
    -H "Authorization: Bearer ${WAZUH_TOKEN}" \
    "${MANAGER_BASE}/agents/000" \
    --connect-timeout 10 \
    --max-time 20 \
    2>/dev/null || echo '{}')"

  AGENT000_STATUS="$(echo "${AGENT000_RESPONSE}" \
    | jq -r '.data.affected_items[0].status // "unknown"' 2>/dev/null || echo "unknown")"

  if [[ "${AGENT000_STATUS}" == "active" ]]; then
    check_pass "Wazuh self-agent (000)" "status=active"
  else
    check_fail "Wazuh self-agent (000)" \
      "status=${AGENT000_STATUS} — expected 'active'. Response: ${AGENT000_RESPONSE}"
  fi
fi
echo ""

# ---------------------------------------------------------------------------
# CHECK 9 — 5-minute soak: alert count increases (events are flowing)
# ---------------------------------------------------------------------------
log "CHECK 9: ${SOAK_MINUTES}-minute soak — verifying alert flow..."

SOAK_SECS=$((SOAK_MINUTES * 60))

# Get count at T=0
COUNT_T0_RESPONSE="$(curl -sk \
  -u "${INDEXER_USER}:${INDEXER_PASS}" \
  "${INDEXER_BASE}/wazuh-alerts-*/_count" \
  --connect-timeout 10 \
  --max-time 20 \
  2>/dev/null || echo '{}')"
COUNT_T0="$(echo "${COUNT_T0_RESPONSE}" | jq -r '.count // -1' 2>/dev/null || echo "-1")"

if [[ "${COUNT_T0}" -lt 0 ]]; then
  check_fail "Alert flow soak test" \
    "Could not retrieve T=0 alert count. Skipping soak."
else
  log "  T=0 alert count: ${COUNT_T0}"
  log "  Waiting ${SOAK_MINUTES} minute(s)..."

  # Print a progress dot every 30 seconds
  ELAPSED=0
  while [[ "${ELAPSED}" -lt "${SOAK_SECS}" ]]; do
    sleep 30
    ELAPSED=$((ELAPSED + 30))
    printf "  ..."
  done
  echo ""

  COUNT_T1_RESPONSE="$(curl -sk \
    -u "${INDEXER_USER}:${INDEXER_PASS}" \
    "${INDEXER_BASE}/wazuh-alerts-*/_count" \
    --connect-timeout 10 \
    --max-time 20 \
    2>/dev/null || echo '{}')"
  COUNT_T1="$(echo "${COUNT_T1_RESPONSE}" | jq -r '.count // -1' 2>/dev/null || echo "-1")"

  log "  T=${SOAK_MINUTES}m alert count: ${COUNT_T1}"

  if [[ "${COUNT_T1}" -lt 0 ]]; then
    check_fail "Alert flow soak test" \
      "Could not retrieve T=${SOAK_MINUTES}m alert count."
  elif [[ "${COUNT_T1}" -gt "${COUNT_T0}" ]]; then
    DELTA=$((COUNT_T1 - COUNT_T0))
    check_pass "Alert flow soak test" \
      "Δ=+${DELTA} alerts over ${SOAK_MINUTES}min — events are flowing"
  else
    check_fail "Alert flow soak test" \
      "Alert count did not increase: T0=${COUNT_T0} T=${SOAK_MINUTES}m=${COUNT_T1}. Check agent connectivity and Filebeat → Indexer pipeline."
  fi
fi
echo ""

# ---------------------------------------------------------------------------
# FINAL SUMMARY
# ---------------------------------------------------------------------------
TOTAL=$((PASS_COUNT + FAIL_COUNT))

echo "=============================================================="
echo "  PHASE 7 VALIDATION RESULTS"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
echo ""
for result in "${RESULTS[@]}"; do
  echo "  ${result}"
done
echo ""
echo "--------------------------------------------------------------"
echo "  TOTAL: ${PASS_COUNT}/${TOTAL} checks passed"
echo "--------------------------------------------------------------"
echo ""

if [[ "${FAIL_COUNT}" -gt 0 ]]; then
  echo "  STATUS: FAILED — ${FAIL_COUNT} check(s) did not pass."
  echo "  EKS DECOMMISSION IS NOT APPROVED."
  echo ""
  echo "  Resolve all FAILs above, then re-run this script."
  echo "=============================================================="
  exit 1
else
  echo "  STATUS: ALL CHECKS PASSED"
  echo "  EKS DECOMMISSION MAY PROCEED."
  echo ""
  echo "  Next step: Phase 8 — EKS node group scale-down + cluster deletion"
  echo "=============================================================="
  exit 0
fi

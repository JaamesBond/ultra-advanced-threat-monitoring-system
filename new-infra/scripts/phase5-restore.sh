#!/usr/bin/env bash
# =============================================================================
# phase5-restore.sh — XDR v8 / bc-ctrl EKS → bare EC2 migration
# Phase 5: Restore data from Phase 1 backups to new EC2 instances
#
# Run from a host that has:
#   - AWS CLI (eu-central-1) + appropriate IAM permissions
#   - SSH access to INDEXER_IP and MISP_IP (or SSM, adapt accordingly)
#   - jq, curl
#
# Required env vars:
#   INDEXER_IP    — private IP of new Wazuh Indexer EC2
#   MISP_IP       — private IP of new MISP EC2
#   BACKUP_DATE   — datestamp from backup manifest (format: YYYYMMDD-HHMM)
#                   e.g. 20260415-0300
#
# Optional:
#   REGION              — AWS region (default: eu-central-1)
#   BACKUP_BUCKET       — S3 bucket used for backups (default: bc-uatms-terraform-state)
#   SNAPSHOT_BUCKET     — S3 bucket for OpenSearch snapshots (default: bc-uatms-wazuh-snapshots)
#   WAZUH_MANAGER_IP    — private IP of Wazuh Manager (for restart after restore)
#   INDEXER_PORT        — OpenSearch port (default: 9200)
#   SSH_KEY             — path to SSH key for remote commands (default: ~/.ssh/id_rsa)
#   SSH_USER            — SSH user on EC2 instances (default: ec2-user)
#   RESTORE_TIMEOUT_SEC — max seconds to wait for snapshot restore (default: 3600)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REGION="${REGION:-eu-central-1}"
BACKUP_BUCKET="${BACKUP_BUCKET:-bc-uatms-terraform-state}"
SNAPSHOT_BUCKET="${SNAPSHOT_BUCKET:-bc-uatms-wazuh-snapshots}"
BACKUP_PREFIX="backups"
INDEXER_PORT="${INDEXER_PORT:-9200}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/id_rsa}"
SSH_USER="${SSH_USER:-ec2-user}"
RESTORE_TIMEOUT_SEC="${RESTORE_TIMEOUT_SEC:-3600}"
WAZUH_MANAGER_SECRET="bc/wazuh/manager"
SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME}] $*"; }
fail() { log "FATAL: $1"; exit 1; }

require_env() {
  local var="$1"
  [[ -n "${!var:-}" ]] || { echo "ERROR: Required env var ${var} is not set."; exit 1; }
}

# SSH helper — uses SSM-compatible options (no ControlMaster to avoid reuse issues)
remote_exec() {
  local host="$1"
  shift
  ssh -i "${SSH_KEY}" \
      -o StrictHostKeyChecking=no \
      -o BatchMode=yes \
      -o ConnectTimeout=20 \
      -o ServerAliveInterval=30 \
      "${SSH_USER}@${host}" "$@"
}

# Run a command on the remote host via SSM (use when SSH is not available)
# Override this function if using SSM instead of direct SSH
ssm_exec() {
  local instance_id="$1"
  local region="$2"
  shift 2
  local cmd_str="$*"
  CMD_ID="$(aws ssm send-command \
    --region "${region}" \
    --instance-ids "${instance_id}" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"${cmd_str}\"]" \
    --query 'Command.CommandId' \
    --output text)"
  aws ssm wait command-executed \
    --region "${region}" \
    --command-id "${CMD_ID}" \
    --instance-id "${instance_id}" 2>/dev/null || true
  aws ssm get-command-invocation \
    --region "${region}" \
    --command-id "${CMD_ID}" \
    --instance-id "${instance_id}" \
    --query 'StandardOutputContent' \
    --output text
}

# ---------------------------------------------------------------------------
# Validate required env vars
# ---------------------------------------------------------------------------
require_env INDEXER_IP
require_env MISP_IP
require_env BACKUP_DATE

# ---------------------------------------------------------------------------
# Fetch INDEXER_PASSWORD from Secrets Manager
# ---------------------------------------------------------------------------
log "Fetching INDEXER_PASSWORD from Secrets Manager..."
SECRET_JSON="$(aws secretsmanager get-secret-value \
  --region "${REGION}" \
  --secret-id "${WAZUH_MANAGER_SECRET}" \
  --query 'SecretString' \
  --output text)" || fail "Could not fetch secret ${WAZUH_MANAGER_SECRET}"
INDEXER_PASSWORD="$(echo "${SECRET_JSON}" | jq -r '.INDEXER_PASSWORD')"
INDEXER_USERNAME="$(echo "${SECRET_JSON}" | jq -r '.INDEXER_USERNAME // "admin"')"
MISP_SECRET_JSON="$(aws secretsmanager get-secret-value \
  --region "${REGION}" \
  --secret-id "bc/misp" \
  --query 'SecretString' \
  --output text)" || fail "Could not fetch secret bc/misp"
MYSQL_ROOT_PASSWORD="$(echo "${MISP_SECRET_JSON}" | jq -r '.MYSQL_ROOT_PASSWORD')"
MYSQL_USER="$(echo "${MISP_SECRET_JSON}" | jq -r '.MYSQL_USER // "misp"')"
MYSQL_PASSWORD="$(echo "${MISP_SECRET_JSON}" | jq -r '.MYSQL_PASSWORD')"

INDEXER_BASE="https://${INDEXER_IP}:${INDEXER_PORT}"
OS_AUTH="${INDEXER_USERNAME}:${INDEXER_PASSWORD}"

echo ""
echo "=============================================================="
echo "  PHASE 5 RESTORE — XDR v8 Migration"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
echo "  Indexer  : ${INDEXER_BASE}"
echo "  MISP     : ${MISP_IP}"
echo "  Backup   : ${BACKUP_DATE}"
echo "  Bucket   : s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}"
echo "  Snapshots: s3://${SNAPSHOT_BUCKET}"
echo "=============================================================="
echo ""

# ===========================================================================
# STEP 1 — Restore OpenSearch snapshot
# ===========================================================================
log "=== STEP 1: Restore OpenSearch snapshot ==="

# Wait for indexer to be healthy before restoring
log "Waiting for Wazuh Indexer to be healthy..."
HEALTH_OK=false
for i in $(seq 1 60); do
  HEALTH="$(curl -sk -u "${OS_AUTH}" \
    "${INDEXER_BASE}/_cluster/health" \
    --connect-timeout 5 --max-time 10 2>/dev/null \
    | jq -r '.status // "unreachable"' 2>/dev/null || echo "unreachable")"
  if [[ "${HEALTH}" == "green" || "${HEALTH}" == "yellow" ]]; then
    log "Indexer cluster health: ${HEALTH}"
    HEALTH_OK=true
    break
  fi
  [[ $((i % 6)) -eq 0 ]] && log "  Still waiting... health=${HEALTH} ($((i * 10))s)"
  sleep 10
done
"${HEALTH_OK}" || fail "Indexer did not reach healthy state within 600s"

# Discover which snapshot to restore:
# Prefer "final-snap-*" (created by phase6-cutover.sh) over "migration-snap-*"
SNAP_DATE="${BACKUP_DATE%%-*}"    # extract YYYYMMDD portion
SNAP_REPO_NAME="restore-${SNAP_DATE}"
SNAP_BASE_PATH="opensearch-snapshots/${BACKUP_DATE}"

log "Checking for final-snap-* in S3 at s3://${SNAPSHOT_BUCKET}..."
FINAL_SNAP_MANIFEST="$(aws s3 ls \
  "s3://${SNAPSHOT_BUCKET}/opensearch-snapshots/" \
  --region "${REGION}" 2>/dev/null \
  | grep "final-snap-" | sort -r | head -1 || true)"

if [[ -n "${FINAL_SNAP_MANIFEST}" ]]; then
  # Extract the path portion — looks like:  PRE final-snap-20260415.../
  FINAL_DATE="$(echo "${FINAL_SNAP_MANIFEST}" | awk '{print $NF}' | tr -d '/')"
  SNAP_BASE_PATH="opensearch-snapshots/${FINAL_DATE}"
  SNAP_NAME="${FINAL_DATE}"
  log "Using final snapshot: s3://${SNAPSHOT_BUCKET}/${SNAP_BASE_PATH}"
else
  SNAP_NAME="pre-migration-${BACKUP_DATE}"
  log "No final-snap found — using pre-migration snapshot: ${SNAP_NAME}"
  log "  Path: s3://${SNAPSHOT_BUCKET}/${SNAP_BASE_PATH}"
fi

# Register S3 snapshot repository on the new indexer
log "Registering snapshot repository '${SNAP_REPO_NAME}'..."
REPO_RESP="$(curl -sk -u "${OS_AUTH}" \
  -X PUT "${INDEXER_BASE}/_snapshot/${SNAP_REPO_NAME}" \
  -H 'Content-Type: application/json' \
  -d "{
    \"type\": \"s3\",
    \"settings\": {
      \"bucket\": \"${SNAPSHOT_BUCKET}\",
      \"region\": \"${REGION}\",
      \"base_path\": \"${SNAP_BASE_PATH}\",
      \"compress\": true,
      \"server_side_encryption\": true,
      \"readonly\": true
    }
  }" \
  --connect-timeout 10 --max-time 30 2>/dev/null || echo '{}')"

if echo "${REPO_RESP}" | jq -e '.acknowledged == true' >/dev/null 2>&1; then
  log "Snapshot repository registered."
else
  log "Repository response: ${REPO_RESP}"
  fail "Failed to register snapshot repository — check EC2 instance profile has S3 access to ${SNAPSHOT_BUCKET}"
fi

# Verify the snapshot exists in the repo
log "Verifying snapshot exists in repository..."
SNAP_LIST="$(curl -sk -u "${OS_AUTH}" \
  "${INDEXER_BASE}/_snapshot/${SNAP_REPO_NAME}/_all" \
  --connect-timeout 10 --max-time 30 2>/dev/null || echo '{}')"

AVAILABLE_SNAPS="$(echo "${SNAP_LIST}" | jq -r '.snapshots[].snapshot // empty' 2>/dev/null | head -5)"
log "Available snapshots in repo:"
echo "${AVAILABLE_SNAPS}" | sed 's/^/    /'

# Pick the best snapshot name from what's actually available
RESTORE_SNAP="$(echo "${AVAILABLE_SNAPS}" | grep "final-snap-" | head -1 || true)"
if [[ -z "${RESTORE_SNAP}" ]]; then
  RESTORE_SNAP="$(echo "${AVAILABLE_SNAPS}" | grep "pre-migration-" | head -1 || true)"
fi
if [[ -z "${RESTORE_SNAP}" ]]; then
  RESTORE_SNAP="$(echo "${AVAILABLE_SNAPS}" | head -1)"
fi
[[ -n "${RESTORE_SNAP}" ]] || fail "No snapshots found in repository. Check S3 path: s3://${SNAPSHOT_BUCKET}/${SNAP_BASE_PATH}"
log "Restoring snapshot: ${RESTORE_SNAP}"

# Close any existing wazuh-* indices before restore (required by OpenSearch)
log "Closing existing wazuh-* indices (if any) before restore..."
curl -sk -u "${OS_AUTH}" \
  -X POST "${INDEXER_BASE}/wazuh-*/_close" \
  -H 'Content-Type: application/json' \
  --connect-timeout 10 --max-time 60 2>/dev/null \
  || log "  No existing wazuh-* indices to close (expected on fresh install)."

# Trigger restore
log "Starting restore of '${RESTORE_SNAP}'..."
RESTORE_RESP="$(curl -sk -u "${OS_AUTH}" \
  -X POST "${INDEXER_BASE}/_snapshot/${SNAP_REPO_NAME}/${RESTORE_SNAP}/_restore?wait_for_completion=false" \
  -H 'Content-Type: application/json' \
  -d '{
    "indices": "wazuh-*",
    "ignore_unavailable": true,
    "include_global_state": false,
    "rename_pattern": "wazuh-(.*)",
    "rename_replacement": "wazuh-$1",
    "include_aliases": false
  }' \
  --connect-timeout 10 --max-time 60 2>/dev/null || echo '{}')"

if echo "${RESTORE_RESP}" | jq -e '.accepted == true or (.snapshot.state == "SUCCESS")' >/dev/null 2>&1; then
  log "Restore accepted."
elif echo "${RESTORE_RESP}" | jq -e '.error' >/dev/null 2>&1; then
  log "Restore response: ${RESTORE_RESP}"
  fail "Snapshot restore failed — check indexer logs and ensure the snapshot is readable"
else
  log "Restore response: ${RESTORE_RESP}"
  log "WARNING: Unexpected restore response — proceeding to poll recovery status"
fi

# Poll restore progress
log "Polling snapshot restore progress (timeout: ${RESTORE_TIMEOUT_SEC}s)..."
RESTORE_DONE=false
POLL_START="$(date +%s)"

while true; do
  RECOVERY="$(curl -sk -u "${OS_AUTH}" \
    "${INDEXER_BASE}/_cat/recovery?v&format=json&active_only=true" \
    --connect-timeout 10 --max-time 30 2>/dev/null || echo '[]')"

  ACTIVE_SHARDS="$(echo "${RECOVERY}" | jq '[.[] | select(.type=="snapshot")] | length' 2>/dev/null || echo "0")"
  ELAPSED=$(( $(date +%s) - POLL_START ))

  if [[ "${ACTIVE_SHARDS}" -eq 0 ]]; then
    # Verify indices are actually available
    IDX_HEALTH="$(curl -sk -u "${OS_AUTH}" \
      "${INDEXER_BASE}/_cluster/health/wazuh-*" \
      --connect-timeout 5 --max-time 10 2>/dev/null \
      | jq -r '.status // "unknown"' 2>/dev/null || echo "unknown")"
    if [[ "${IDX_HEALTH}" == "green" || "${IDX_HEALTH}" == "yellow" ]]; then
      log "Restore complete — wazuh-* indices health: ${IDX_HEALTH} (${ELAPSED}s)"
      RESTORE_DONE=true
      break
    fi
  fi

  if [[ "${ELAPSED}" -ge "${RESTORE_TIMEOUT_SEC}" ]]; then
    log "WARNING: Restore did not complete within ${RESTORE_TIMEOUT_SEC}s"
    log "  Active snapshot shards remaining: ${ACTIVE_SHARDS}"
    log "  Check manually: curl -sk -u admin:<pass> ${INDEXER_BASE}/_cat/recovery?v"
    break
  fi

  [[ $((ELAPSED % 60)) -lt 10 ]] && log "  Restoring... active shards: ${ACTIVE_SHARDS} (${ELAPSED}s elapsed)"
  sleep 10
done

ALERT_COUNT="$(curl -sk -u "${OS_AUTH}" \
  "${INDEXER_BASE}/wazuh-alerts-*/_count" \
  --connect-timeout 5 --max-time 15 2>/dev/null \
  | jq -r '.count // "unknown"' 2>/dev/null || echo "unknown")"
log "Post-restore alert count: ${ALERT_COUNT}"
echo ""

# ===========================================================================
# STEP 2 — Restore MISP MySQL
# ===========================================================================
log "=== STEP 2: Restore MISP MySQL from s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/misp/mysql-dump-${BACKUP_DATE}.sql.gz ==="

MYSQL_DUMP_S3="s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/misp/mysql-dump-${BACKUP_DATE}.sql.gz"
MYSQL_DUMP_LOCAL="/tmp/misp-mysql-dump-restore-${BACKUP_DATE}.sql.gz"

log "Downloading MySQL dump to ${MYSQL_DUMP_LOCAL}..."
aws s3 cp "${MYSQL_DUMP_S3}" "${MYSQL_DUMP_LOCAL}" \
  --region "${REGION}" \
  || fail "Could not download MySQL dump from ${MYSQL_DUMP_S3} — verify BACKUP_DATE is correct"

DUMP_SIZE="$(du -sh "${MYSQL_DUMP_LOCAL}" | cut -f1)"
log "Download complete: ${DUMP_SIZE}"

log "Importing MySQL dump on MISP host (${MISP_IP})..."
# Upload dump to MISP host, import it, then clean up
scp -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    -o ConnectTimeout=20 \
    "${MYSQL_DUMP_LOCAL}" \
    "${SSH_USER}@${MISP_IP}:/tmp/misp-mysql-dump-restore.sql.gz" \
  || fail "Failed to SCP MySQL dump to ${MISP_IP} — check SSH access"

remote_exec "${MISP_IP}" bash -s <<REMOTE
set -euo pipefail
echo "Importing MISP MySQL dump..."
mysql -u root -p'${MYSQL_ROOT_PASSWORD}' misp -e "DROP DATABASE IF EXISTS misp; CREATE DATABASE misp CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null
zcat /tmp/misp-mysql-dump-restore.sql.gz | mysql -u root -p'${MYSQL_ROOT_PASSWORD}' misp
echo "MySQL import complete."
MISP_TABLE_COUNT=\$(mysql -u root -p'${MYSQL_ROOT_PASSWORD}' misp -se "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='misp';" 2>/dev/null)
echo "MISP tables restored: \${MISP_TABLE_COUNT}"
rm -f /tmp/misp-mysql-dump-restore.sql.gz
REMOTE

rm -f "${MYSQL_DUMP_LOCAL}"
log "MySQL restore complete."
echo ""

# ===========================================================================
# STEP 3 — Restore MISP files
# ===========================================================================
log "=== STEP 3: Restore MISP files from s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/misp/files-${BACKUP_DATE}.tar.gz ==="

MISP_FILES_S3="s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/misp/files-${BACKUP_DATE}.tar.gz"
MISP_FILES_LOCAL="/tmp/misp-files-restore-${BACKUP_DATE}.tar.gz"

log "Downloading MISP files archive..."
aws s3 cp "${MISP_FILES_S3}" "${MISP_FILES_LOCAL}" \
  --region "${REGION}" \
  || fail "Could not download MISP files from ${MISP_FILES_S3}"

FILES_SIZE="$(du -sh "${MISP_FILES_LOCAL}" | cut -f1)"
log "Download complete: ${FILES_SIZE}"

log "Restoring MISP files on ${MISP_IP}..."
scp -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    -o ConnectTimeout=20 \
    "${MISP_FILES_LOCAL}" \
    "${SSH_USER}@${MISP_IP}:/tmp/misp-files-restore.tar.gz" \
  || fail "Failed to SCP MISP files to ${MISP_IP}"

remote_exec "${MISP_IP}" bash -s <<'REMOTE'
set -euo pipefail
echo "Extracting MISP files to /data/misp-files..."
mkdir -p /data/misp-files
# The tar was created from /var/www/MISP/app/files inside the container;
# strip the leading path components to extract directly to /data/misp-files
tar -xzf /tmp/misp-files-restore.tar.gz \
    -C /data/misp-files \
    --strip-components=4 \
    2>/dev/null \
  || tar -xzf /tmp/misp-files-restore.tar.gz \
      -C / \
      2>/dev/null
chown -R apache:apache /data/misp-files 2>/dev/null || true
echo "MISP files restored."
rm -f /tmp/misp-files-restore.tar.gz
REMOTE

rm -f "${MISP_FILES_LOCAL}"
log "MISP files restore complete."
echo ""

# ===========================================================================
# STEP 4 — Restore Wazuh Manager state
# ===========================================================================
log "=== STEP 4: Restore Wazuh Manager state ==="

MANAGER_STATE_S3="s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/wazuh/manager-state-${BACKUP_DATE}.tar.gz"
MANAGER_STATE_LOCAL="/tmp/wazuh-manager-state-restore-${BACKUP_DATE}.tar.gz"
MANAGER_IP="${WAZUH_MANAGER_IP:-}"

if [[ -z "${MANAGER_IP}" ]]; then
  log "Discovering Wazuh Manager IP (tag Name=wazuh-manager-ctrl)..."
  MANAGER_IP="$(aws ec2 describe-instances \
    --region "${REGION}" \
    --filters "Name=tag:Name,Values=wazuh-manager-ctrl" \
              "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' \
    --output text 2>/dev/null || true)"
  [[ -n "${MANAGER_IP}" && "${MANAGER_IP}" != "None" ]] \
    || fail "Could not determine Wazuh Manager IP. Set WAZUH_MANAGER_IP env var."
  log "Manager IP: ${MANAGER_IP}"
fi

log "Downloading Wazuh Manager state archive..."
aws s3 cp "${MANAGER_STATE_S3}" "${MANAGER_STATE_LOCAL}" \
  --region "${REGION}" \
  || fail "Could not download Manager state from ${MANAGER_STATE_S3}"

STATE_SIZE="$(du -sh "${MANAGER_STATE_LOCAL}" | cut -f1)"
log "Download complete: ${STATE_SIZE}"

log "Restoring Wazuh Manager state on ${MANAGER_IP}..."
scp -i "${SSH_KEY}" \
    -o StrictHostKeyChecking=no \
    -o BatchMode=yes \
    -o ConnectTimeout=20 \
    "${MANAGER_STATE_LOCAL}" \
    "${SSH_USER}@${MANAGER_IP}:/tmp/wazuh-manager-state-restore.tar.gz" \
  || fail "Failed to SCP Manager state to ${MANAGER_IP}"

remote_exec "${MANAGER_IP}" bash -s <<'REMOTE'
set -euo pipefail
echo "Stopping wazuh-manager for state restore..."
systemctl stop wazuh-manager 2>/dev/null || true
sleep 3

echo "Extracting Wazuh Manager state..."
# The tar was created capturing: /var/ossec/etc, /var/ossec/var/db,
# /var/ossec/queue/agents-timestamp, /var/ossec/queue/fts
tar -xzf /tmp/wazuh-manager-state-restore.tar.gz \
    -C / \
    --overwrite \
    2>/dev/null

echo "Setting correct ownership on /var/ossec..."
chown -R wazuh:wazuh /var/ossec/etc /var/ossec/var/db 2>/dev/null || \
  chown -R 101:101   /var/ossec/etc /var/ossec/var/db 2>/dev/null || true

chown wazuh:wazuh /var/ossec/queue/agents-timestamp 2>/dev/null || true
chown -R wazuh:wazuh /var/ossec/queue/fts 2>/dev/null || true

echo "Restarting wazuh-manager..."
systemctl start wazuh-manager
sleep 10
systemctl is-active wazuh-manager && echo "wazuh-manager: RUNNING" || echo "wazuh-manager: FAILED — check journalctl"

rm -f /tmp/wazuh-manager-state-restore.tar.gz
REMOTE

rm -f "${MANAGER_STATE_LOCAL}"
log "Wazuh Manager state restored and manager restarted."
echo ""

# ===========================================================================
# STEP 5 — Verify agent count
# ===========================================================================
log "=== STEP 5: Verifying agent count ==="

API_USERNAME="$(echo "${SECRET_JSON}" | jq -r '.API_USERNAME // "wazuh-wui"')"
API_PASSWORD="$(echo "${SECRET_JSON}" | jq -r '.API_PASSWORD')"
MANAGER_API_BASE="https://${MANAGER_IP}:55000"

log "Waiting for Manager API to be ready..."
API_OK=false
for i in $(seq 1 18); do
  if TOKEN="$(curl -sfk \
      -u "${API_USERNAME}:${API_PASSWORD}" \
      "${MANAGER_API_BASE}/security/user/authenticate?raw=true" \
      --connect-timeout 5 --max-time 10 2>/dev/null)"; then
    [[ -n "${TOKEN}" ]] && API_OK=true && break
  fi
  sleep 10
done

if "${API_OK}"; then
  AGENTS_RESP="$(curl -sfk \
    -H "Authorization: Bearer ${TOKEN}" \
    "${MANAGER_API_BASE}/agents?status=active&limit=1&select=id" \
    --connect-timeout 5 --max-time 15 2>/dev/null || echo '{}')"
  ACTIVE_AGENTS="$(echo "${AGENTS_RESP}" | jq -r '.data.total_affected_items // 0' 2>/dev/null || echo 0)"
  log "Active agents after restore: ${ACTIVE_AGENTS}"
  log "(Agents will reconnect gradually — expect full count within 10-15 min)"
else
  log "WARNING: Could not reach Manager API after 180s — verify manually"
  ACTIVE_AGENTS="N/A"
fi

# ===========================================================================
# SUMMARY
# ===========================================================================
echo ""
echo "=============================================================="
echo "  PHASE 5 RESTORE COMPLETE"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
echo ""
echo "  What was restored:"
echo "    OpenSearch : wazuh-* indices from snapshot '${RESTORE_SNAP:-unknown}'"
echo "                 alert count: ${ALERT_COUNT}"
echo "    MISP MySQL : ${MYSQL_DUMP_S3}"
echo "    MISP files : ${MISP_FILES_S3}"
echo "    Wazuh state: ${MANAGER_STATE_S3}"
echo ""
echo "  Active agents: ${ACTIVE_AGENTS:-N/A}"
echo ""
echo "  NEXT STEPS:"
echo "    1. Wait 10-15 min for agents to reconnect"
echo "    2. Run phase7-validate.sh to confirm all checks pass"
echo "    3. Only then run phase6-cutover.sh (maintenance window)"
echo "=============================================================="

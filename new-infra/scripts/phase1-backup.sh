#!/usr/bin/env bash
# =============================================================================
# phase1-backup.sh — XDR v8 / bc-ctrl EKS → bare EC2 migration
# Phase 1: Pre-migration backup & snapshot (READ-ONLY against live cluster)
#
# Must be run BEFORE any infrastructure changes.
# Idempotent: safe to re-run; subsequent runs produce a new dated copy.
#
# Required tools: kubectl (connected to bc-ctrl), aws cli (eu-central-1),
#                 jq, curl
#
# Produces a BACKUP_MANIFEST at the end — feed that file into phase5-restore.sh
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REGION="eu-central-1"
SNAPSHOT_BUCKET="bc-uatms-wazuh-snapshots"
BACKUP_BUCKET="bc-uatms-terraform-state"
BACKUP_PREFIX="backups"
DATE="$(date +%Y%m%d-%H%M)"
NAMESPACES=("wazuh" "misp")

# OpenSearch snapshot settings
OPENSEARCH_REPO_NAME="migration-backup-${DATE}"
OPENSEARCH_SNAPSHOT_NAME="pre-migration-${DATE}"
OPENSEARCH_PORT_FWD_LOCAL=19200   # local port for kubectl port-forward

# Wazuh Manager secret (AWS Secrets Manager path from external-secrets.yaml)
WAZUH_MANAGER_SECRET="bc/wazuh/manager"
# MISP secret (AWS Secrets Manager path from misp/external-secrets.yaml)
MISP_SECRET="bc/misp"

# Manifest accumulator
MANIFEST_FILE="/tmp/backup-manifest-${DATE}.txt"
EBS_SNAPSHOT_IDS=()
S3_PATHS=()

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

fail() {
  echo ""
  echo "=========================================================="
  echo "  STEP FAILED: $1"
  echo "  What to check: $2"
  echo "=========================================================="
  exit 1
}

manifest_add() {
  echo "$1" >> "${MANIFEST_FILE}"
}

# ---------------------------------------------------------------------------
# STEP 0 — Prerequisites
# ---------------------------------------------------------------------------
log "=== STEP 0: Checking prerequisites ==="

log "  Checking kubectl..."
kubectl cluster-info --request-timeout=10s >/dev/null 2>&1 \
  || fail "kubectl not connected" \
    "Run: aws eks update-kubeconfig --region ${REGION} --name bc-ctrl"

KUBE_CONTEXT="$(kubectl config current-context)"
log "  kubectl context: ${KUBE_CONTEXT}"

log "  Checking AWS CLI..."
aws sts get-caller-identity --region "${REGION}" >/dev/null 2>&1 \
  || fail "AWS CLI not configured" \
    "Run: aws configure  OR  set AWS_PROFILE / AWS_ACCESS_KEY_ID"

AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
log "  AWS account: ${AWS_ACCOUNT_ID}"

log "  Checking jq..."
command -v jq >/dev/null 2>&1 \
  || fail "jq not installed" "Install jq: https://stedolan.github.io/jq/"

log "  Checking curl..."
command -v curl >/dev/null 2>&1 \
  || fail "curl not installed" "Install curl via your package manager"

log "Prerequisites OK."
echo ""

# ---------------------------------------------------------------------------
# STEP 1 — Create & harden the OpenSearch snapshot bucket
# ---------------------------------------------------------------------------
log "=== STEP 1: Creating S3 bucket ${SNAPSHOT_BUCKET} ==="

BUCKET_EXISTS="$(aws s3api head-bucket --bucket "${SNAPSHOT_BUCKET}" \
  --region "${REGION}" 2>&1 || true)"

if echo "${BUCKET_EXISTS}" | grep -q "404\|NoSuchBucket\|Not Found"; then
  log "  Bucket does not exist — creating..."
  aws s3api create-bucket \
    --bucket "${SNAPSHOT_BUCKET}" \
    --region "${REGION}" \
    --create-bucket-configuration LocationConstraint="${REGION}"
  log "  Bucket created."
else
  log "  Bucket already exists — skipping creation."
fi

log "  Enabling versioning..."
aws s3api put-bucket-versioning \
  --bucket "${SNAPSHOT_BUCKET}" \
  --versioning-configuration Status=Enabled \
  --region "${REGION}"

log "  Applying server-side encryption (AES256)..."
aws s3api put-bucket-encryption \
  --bucket "${SNAPSHOT_BUCKET}" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": {
        "SSEAlgorithm": "AES256"
      },
      "BucketKeyEnabled": true
    }]
  }' \
  --region "${REGION}"

log "  Blocking all public access..."
aws s3api put-public-access-block \
  --bucket "${SNAPSHOT_BUCKET}" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true" \
  --region "${REGION}"

log "  Enabling Object Lock (COMPLIANCE, 30-day default retention)..."
# Object Lock must be enabled at bucket creation time; if bucket is new the
# next call succeeds. If bucket already existed without Object Lock this will
# fail — that is intentional (operator must remediate manually).
aws s3api put-object-lock-configuration \
  --bucket "${SNAPSHOT_BUCKET}" \
  --object-lock-configuration '{
    "ObjectLockEnabled": "Enabled",
    "Rule": {
      "DefaultRetention": {
        "Mode": "COMPLIANCE",
        "Days": 30
      }
    }
  }' \
  --region "${REGION}" \
  || log "  WARNING: Object Lock could not be set (bucket may pre-date this run without Object Lock). Verify manually."

log "  S3 snapshot bucket ready: s3://${SNAPSHOT_BUCKET}"
manifest_add "SNAPSHOT_BUCKET=s3://${SNAPSHOT_BUCKET}"
echo ""

# ---------------------------------------------------------------------------
# STEP 2 — EBS snapshots for all PVCs (wazuh + misp namespaces)
# ---------------------------------------------------------------------------
log "=== STEP 2: Snapshotting EBS volumes backing PVCs ==="

snapshot_pvcs_in_namespace() {
  local ns="$1"
  log "  Namespace: ${ns}"

  local pvcs
  pvcs="$(kubectl get pvc -n "${ns}" -o json 2>/dev/null)" \
    || { log "  WARNING: Could not list PVCs in namespace ${ns}"; return; }

  local pvc_count
  pvc_count="$(echo "${pvcs}" | jq '.items | length')"
  log "  Found ${pvc_count} PVC(s) in ${ns}"

  echo "${pvcs}" | jq -c '.items[]' | while read -r pvc; do
    local pvc_name pv_name
    pvc_name="$(echo "${pvc}" | jq -r '.metadata.name')"
    pv_name="$(echo "${pvc}" | jq -r '.spec.volumeName // empty')"

    if [[ -z "${pv_name}" ]]; then
      log "  WARNING: PVC ${pvc_name} has no bound PV — skipping"
      continue
    fi

    # Get the EBS volume ID from the PV spec
    local vol_id
    vol_id="$(kubectl get pv "${pv_name}" -o json \
      | jq -r '.spec.csi.volumeHandle // .spec.awsElasticBlockStore.volumeID // empty' \
      | sed 's|.*vol-|vol-|')"  # strip any aws:// prefix

    if [[ -z "${vol_id}" ]]; then
      log "  WARNING: Could not extract EBS volume ID for PV ${pv_name} (PVC ${pvc_name}) — skipping"
      continue
    fi

    log "  Snapshotting PVC=${pvc_name} PV=${pv_name} EBS=${vol_id}"

    local snap_id
    snap_id="$(aws ec2 create-snapshot \
      --region "${REGION}" \
      --volume-id "${vol_id}" \
      --description "Phase1-pre-migration PVC=${pvc_name} NS=${ns} Date=${DATE}" \
      --tag-specifications "ResourceType=snapshot,Tags=[
        {Key=MigrationPhase,Value=pre},
        {Key=Date,Value=${DATE}},
        {Key=PVCName,Value=${pvc_name}},
        {Key=Namespace,Value=${ns}},
        {Key=PVName,Value=${pv_name}},
        {Key=Project,Value=xdr-v8-migration}
      ]" \
      --query 'SnapshotId' \
      --output text)" \
      || fail "EBS snapshot creation" "Check IAM permissions: ec2:CreateSnapshot on volume ${vol_id}"

    log "  Snapshot initiated: ${snap_id} (async — check console for completion)"
    EBS_SNAPSHOT_IDS+=("${snap_id}:${ns}/${pvc_name}")
    manifest_add "EBS_SNAPSHOT=${snap_id} pvc=${ns}/${pvc_name} ebs=${vol_id}"
  done
}

for ns in "${NAMESPACES[@]}"; do
  snapshot_pvcs_in_namespace "${ns}"
done

log "  EBS snapshot requests submitted for all namespaces."
echo ""

# ---------------------------------------------------------------------------
# STEP 3 — Wazuh Indexer → OpenSearch S3 snapshot
# ---------------------------------------------------------------------------
# SKIPPED: repository-s3 plugin not installed in the Wazuh Indexer image.
# Data is covered by EBS volume snapshots taken in Step 2.
# Phase 5 restore will use EBS snapshot → new volume → attach to EC2 indexer.
log "=== STEP 3: OpenSearch S3 snapshot — SKIPPED (no repository-s3 plugin) ==="
log "  Indexer data is covered by EBS snapshots from Step 2. Continuing..."
manifest_add "OPENSEARCH_SNAPSHOT_METHOD=ebs_snapshot"
echo ""

if false; then
log "  Fetching INDEXER_PASSWORD from Secrets Manager (${WAZUH_MANAGER_SECRET})..."
INDEXER_PASSWORD="$(aws secretsmanager get-secret-value \
  --region "${REGION}" \
  --secret-id "${WAZUH_MANAGER_SECRET}" \
  --query 'SecretString' \
  --output text \
  | jq -r '.INDEXER_PASSWORD')" \
  || fail "Secrets Manager fetch (${WAZUH_MANAGER_SECRET})" \
    "Ensure the secret exists and your IAM role has secretsmanager:GetSecretValue"

log "  INDEXER_PASSWORD retrieved."

log "  Starting kubectl port-forward to wazuh-indexer-0:9200..."
# Kill any stale port-forward on the same local port
pkill -f "kubectl port-forward.*${OPENSEARCH_PORT_FWD_LOCAL}" 2>/dev/null || true
sleep 1

kubectl port-forward \
  -n wazuh \
  svc/wazuh-indexer \
  "${OPENSEARCH_PORT_FWD_LOCAL}:9200" \
  >/tmp/pf-indexer.log 2>&1 &
PF_PID=$!

# Wait until port-forward is ready
log "  Waiting for port-forward to be ready..."
for i in $(seq 1 20); do
  if curl -sk -u "admin:${INDEXER_PASSWORD}" \
    "https://localhost:${OPENSEARCH_PORT_FWD_LOCAL}/_cluster/health" \
    >/dev/null 2>&1; then
    log "  Port-forward ready after ${i}s"
    break
  fi
  if [[ "${i}" -eq 20 ]]; then
    kill "${PF_PID}" 2>/dev/null || true
    fail "OpenSearch port-forward" \
      "Check: kubectl get pods -n wazuh | grep indexer; cat /tmp/pf-indexer.log"
  fi
  sleep 2
done

OS_URL="https://localhost:${OPENSEARCH_PORT_FWD_LOCAL}"
OS_AUTH="admin:${INDEXER_PASSWORD}"

# Derive the IAM role ARN used by the EKS IRSA/Pod Identity for the indexer SA
# (needed for the OpenSearch S3 repository plugin to sign S3 requests)
log "  Resolving IAM role for OpenSearch S3 repository access..."
# The snapshot plugin on the target EC2 will use instance profile; for EKS we
# pass the full bucket path and rely on the node IAM role that already has
# access to the snapshot bucket (granted when the bucket is created).
# We use path_style_access for cross-account safety.

log "  Registering S3 snapshot repository '${OPENSEARCH_REPO_NAME}'..."
REPO_RESPONSE="$(curl -sk -u "${OS_AUTH}" \
  -X PUT "${OS_URL}/_snapshot/${OPENSEARCH_REPO_NAME}" \
  -H 'Content-Type: application/json' \
  -d "{
    \"type\": \"s3\",
    \"settings\": {
      \"bucket\": \"${SNAPSHOT_BUCKET}\",
      \"region\": \"${REGION}\",
      \"base_path\": \"opensearch-snapshots/${DATE}\",
      \"compress\": true,
      \"server_side_encryption\": true
    }
  }")" || true

if echo "${REPO_RESPONSE}" | jq -e '.acknowledged == true' >/dev/null 2>&1; then
  log "  Repository registered successfully."
else
  kill "${PF_PID}" 2>/dev/null || true
  echo "  OpenSearch response: ${REPO_RESPONSE}"
  fail "OpenSearch snapshot repository registration" \
    "Ensure the node IAM role has s3:PutObject / s3:GetObject on ${SNAPSHOT_BUCKET}. Check opensearch-s3 plugin is installed in the indexer image."
fi

log "  Creating snapshot '${OPENSEARCH_SNAPSHOT_NAME}' of all wazuh-* indices..."
SNAP_RESPONSE="$(curl -sk -u "${OS_AUTH}" \
  -X PUT "${OS_URL}/_snapshot/${OPENSEARCH_REPO_NAME}/${OPENSEARCH_SNAPSHOT_NAME}?wait_for_completion=false" \
  -H 'Content-Type: application/json' \
  -d '{
    "indices": "wazuh-*",
    "ignore_unavailable": true,
    "include_global_state": false
  }')" || true

if echo "${SNAP_RESPONSE}" | jq -e '.accepted == true' >/dev/null 2>&1; then
  log "  Snapshot accepted — polling for completion (this may take several minutes)..."
else
  kill "${PF_PID}" 2>/dev/null || true
  echo "  OpenSearch response: ${SNAP_RESPONSE}"
  fail "OpenSearch snapshot creation" \
    "Check cluster health: curl -sk -u admin:<pass> https://<indexer>:9200/_cluster/health"
fi

# Poll for completion (max 60 minutes)
SNAP_STATUS="IN_PROGRESS"
for i in $(seq 1 360); do
  sleep 10
  STATUS_RESPONSE="$(curl -sk -u "${OS_AUTH}" \
    "${OS_URL}/_snapshot/${OPENSEARCH_REPO_NAME}/${OPENSEARCH_SNAPSHOT_NAME}/_status" \
    2>/dev/null || echo '{}')"

  SNAP_STATUS="$(echo "${STATUS_RESPONSE}" \
    | jq -r '.snapshots[0].state // "UNKNOWN"' 2>/dev/null || echo "UNKNOWN")"

  if [[ "${SNAP_STATUS}" == "SUCCESS" ]]; then
    log "  Snapshot completed successfully (${i}0s elapsed)."
    break
  elif [[ "${SNAP_STATUS}" == "FAILED" || "${SNAP_STATUS}" == "PARTIAL" ]]; then
    kill "${PF_PID}" 2>/dev/null || true
    echo "  Status response: ${STATUS_RESPONSE}"
    fail "OpenSearch snapshot" "Snapshot state: ${SNAP_STATUS}. Check indexer logs: kubectl logs -n wazuh wazuh-indexer-0"
  fi

  if [[ $((i % 6)) -eq 0 ]]; then
    log "  Still snapshotting... status=${SNAP_STATUS} (${i}0s elapsed)"
  fi

  if [[ "${i}" -eq 360 ]]; then
    kill "${PF_PID}" 2>/dev/null || true
    fail "OpenSearch snapshot timeout" "Snapshot ran >60min. Check status manually: curl -sk -u admin:<pass> ${OS_URL}/_snapshot/${OPENSEARCH_REPO_NAME}/${OPENSEARCH_SNAPSHOT_NAME}/_status"
  fi
done

kill "${PF_PID}" 2>/dev/null || true
log "  OpenSearch snapshot status: ${SNAP_STATUS}"

OS_SNAP_PATH="s3://${SNAPSHOT_BUCKET}/opensearch-snapshots/${DATE}/"
S3_PATHS+=("${OS_SNAP_PATH}")
manifest_add "OPENSEARCH_SNAPSHOT_REPO=${OPENSEARCH_REPO_NAME}"
manifest_add "OPENSEARCH_SNAPSHOT_NAME=${OPENSEARCH_SNAPSHOT_NAME}"
manifest_add "OPENSEARCH_SNAPSHOT_S3=${OS_SNAP_PATH}"
echo ""
fi # end skipped block

# ---------------------------------------------------------------------------
# STEP 4 — MISP MySQL dump
# ---------------------------------------------------------------------------
log "=== STEP 4: MISP MySQL dump ==="

log "  Fetching MYSQL_ROOT_PASSWORD from Secrets Manager (${MISP_SECRET})..."
MYSQL_ROOT_PASSWORD="$(aws secretsmanager get-secret-value \
  --region "${REGION}" \
  --secret-id "${MISP_SECRET}" \
  --query 'SecretString' \
  --output text \
  | jq -r '.MYSQL_ROOT_PASSWORD')" \
  || fail "Secrets Manager fetch (${MISP_SECRET})" \
    "Ensure the secret exists and your IAM role has secretsmanager:GetSecretValue"

log "  MYSQL_ROOT_PASSWORD retrieved."

MYSQL_DUMP_LOCAL="/tmp/misp-mysql-dump-${DATE}.sql.gz"
MYSQL_S3_PATH="s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/misp/mysql-dump-${DATE}.sql.gz"

log "  Running mysqldump inside misp-mysql-0..."
kubectl exec -n misp misp-mysql-0 -- \
  bash -c "mysqldump \
    --single-transaction \
    --routines \
    --triggers \
    --all-databases \
    -u root -p\"${MYSQL_ROOT_PASSWORD}\" \
    2>/dev/null \
  | gzip" \
  > "${MYSQL_DUMP_LOCAL}" \
  || fail "mysqldump" \
    "Check pod: kubectl exec -n misp misp-mysql-0 -- mysqladmin ping -uroot -p<pass>"

DUMP_SIZE="$(du -sh "${MYSQL_DUMP_LOCAL}" | cut -f1)"
log "  Dump complete: ${MYSQL_DUMP_LOCAL} (${DUMP_SIZE})"

log "  Uploading to ${MYSQL_S3_PATH}..."
aws s3 cp "${MYSQL_DUMP_LOCAL}" "${MYSQL_S3_PATH}" \
  --sse AES256 \
  --region "${REGION}" \
  || fail "MySQL dump S3 upload" "Check s3:PutObject permission on ${BACKUP_BUCKET}"

log "  MySQL dump uploaded."
S3_PATHS+=("${MYSQL_S3_PATH}")
manifest_add "MISP_MYSQL_DUMP=${MYSQL_S3_PATH}"
rm -f "${MYSQL_DUMP_LOCAL}"
echo ""

# ---------------------------------------------------------------------------
# STEP 5 — MISP files backup
# ---------------------------------------------------------------------------
log "=== STEP 5: MISP application files backup ==="

MISP_FILES_LOCAL="/tmp/misp-files-${DATE}.tar.gz"
MISP_FILES_S3_PATH="s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/misp/files-${DATE}.tar.gz"

log "  Identifying misp-core pod..."
MISP_CORE_POD="$(kubectl get pod -n misp \
  -l app=misp-core \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)" \
  || fail "misp-core pod lookup" "Check: kubectl get pods -n misp"

if [[ -z "${MISP_CORE_POD}" ]]; then
  fail "misp-core pod lookup" "No pod with label app=misp-core found in namespace misp"
fi
log "  Using pod: ${MISP_CORE_POD}"

log "  Tarring /var/www/MISP/app/files from ${MISP_CORE_POD}..."
kubectl exec -n misp "${MISP_CORE_POD}" -- \
  tar czf - /var/www/MISP/app/files 2>/dev/null \
  > "${MISP_FILES_LOCAL}" \
  || fail "MISP files tar" \
    "Check the path exists: kubectl exec -n misp ${MISP_CORE_POD} -- ls /var/www/MISP/app/files"

FILES_SIZE="$(du -sh "${MISP_FILES_LOCAL}" | cut -f1)"
log "  Archive complete: ${MISP_FILES_LOCAL} (${FILES_SIZE})"

log "  Uploading to ${MISP_FILES_S3_PATH}..."
aws s3 cp "${MISP_FILES_LOCAL}" "${MISP_FILES_S3_PATH}" \
  --sse AES256 \
  --region "${REGION}" \
  || fail "MISP files S3 upload" "Check s3:PutObject permission on ${BACKUP_BUCKET}"

log "  MISP files uploaded."
S3_PATHS+=("${MISP_FILES_S3_PATH}")
manifest_add "MISP_FILES=${MISP_FILES_S3_PATH}"
rm -f "${MISP_FILES_LOCAL}"
echo ""

# ---------------------------------------------------------------------------
# STEP 6 — Wazuh Manager agent state backup
# ---------------------------------------------------------------------------
log "=== STEP 6: Wazuh Manager agent state backup ==="

MANAGER_ARCHIVE_LOCAL="/tmp/wazuh-manager-state-${DATE}.tar.gz"
MANAGER_S3_PATH="s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/wazuh/manager-state-${DATE}.tar.gz"

log "  Tarring Wazuh state directories from wazuh-manager-0..."
# Directories: /var/ossec/etc (config), /var/ossec/var/db (agent DBs),
#              /var/ossec/queue/agents-timestamp, /var/ossec/queue/fts (FTS cache)
kubectl exec -n wazuh wazuh-manager-0 -- \
  tar czf - \
    /var/ossec/etc \
    /var/ossec/var/db \
    /var/ossec/queue/agents-timestamp \
    /var/ossec/queue/fts \
    2>/dev/null \
  > "${MANAGER_ARCHIVE_LOCAL}" \
  || fail "Wazuh Manager state tar" \
    "Check pod: kubectl get pod -n wazuh wazuh-manager-0"

MGR_SIZE="$(du -sh "${MANAGER_ARCHIVE_LOCAL}" | cut -f1)"
log "  Archive complete: ${MANAGER_ARCHIVE_LOCAL} (${MGR_SIZE})"

log "  Uploading to ${MANAGER_S3_PATH}..."
aws s3 cp "${MANAGER_ARCHIVE_LOCAL}" "${MANAGER_S3_PATH}" \
  --sse AES256 \
  --region "${REGION}" \
  || fail "Wazuh Manager state S3 upload" "Check s3:PutObject permission on ${BACKUP_BUCKET}"

log "  Manager state uploaded."
S3_PATHS+=("${MANAGER_S3_PATH}")
manifest_add "WAZUH_MANAGER_STATE=${MANAGER_S3_PATH}"
rm -f "${MANAGER_ARCHIVE_LOCAL}"
echo ""

# ---------------------------------------------------------------------------
# STEP 7 — Wazuh agent list
# ---------------------------------------------------------------------------
log "=== STEP 7: Recording Wazuh agent list ==="

AGENT_LIST_LOCAL="/tmp/wazuh-agent-list-${DATE}.txt"
AGENT_LIST_S3_PATH="s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/wazuh/agent-list-${DATE}.txt"

log "  Running agent_control -l on wazuh-manager-0..."
kubectl exec -n wazuh wazuh-manager-0 -- \
  /var/ossec/bin/agent_control -l \
  > "${AGENT_LIST_LOCAL}" \
  || fail "agent_control -l" \
    "Check: kubectl exec -n wazuh wazuh-manager-0 -- /var/ossec/bin/wazuh-control status"

AGENT_COUNT="$(grep -c 'ID:' "${AGENT_LIST_LOCAL}" 2>/dev/null || echo 0)"
log "  Agent list captured: ${AGENT_COUNT} agent entries"

log "  Uploading to ${AGENT_LIST_S3_PATH}..."
aws s3 cp "${AGENT_LIST_LOCAL}" "${AGENT_LIST_S3_PATH}" \
  --sse AES256 \
  --region "${REGION}" \
  || fail "Agent list S3 upload" "Check s3:PutObject permission on ${BACKUP_BUCKET}"

log "  Agent list uploaded."
S3_PATHS+=("${AGENT_LIST_S3_PATH}")
manifest_add "WAZUH_AGENT_LIST=${AGENT_LIST_S3_PATH}"
manifest_add "WAZUH_AGENT_COUNT=${AGENT_COUNT}"

# Save agent count to a local baseline file for phase7-validate.sh
BASELINE_FILE="$(dirname "$0")/wazuh-agent-baseline.txt"
echo "${AGENT_COUNT}" > "${BASELINE_FILE}"
log "  Agent baseline saved to ${BASELINE_FILE} (${AGENT_COUNT} agents)"
manifest_add "AGENT_BASELINE_FILE=${BASELINE_FILE}"

rm -f "${AGENT_LIST_LOCAL}"
echo ""

# ---------------------------------------------------------------------------
# Capture pre-migration alert count (baseline for phase7-validate.sh)
# ---------------------------------------------------------------------------
log "=== STEP 7b: Recording pre-migration alert count baseline ==="

log "  Starting port-forward to wazuh-indexer:9200 for alert count..."
pkill -f "kubectl port-forward.*${OPENSEARCH_PORT_FWD_LOCAL}" 2>/dev/null || true
sleep 1
kubectl port-forward \
  -n wazuh \
  svc/wazuh-indexer \
  "${OPENSEARCH_PORT_FWD_LOCAL}:9200" \
  >/tmp/pf-indexer-baseline.log 2>&1 &
PF_PID2=$!

for i in $(seq 1 20); do
  if curl -sk -u "admin:${INDEXER_PASSWORD}" \
    "https://localhost:${OPENSEARCH_PORT_FWD_LOCAL}/_cluster/health" \
    >/dev/null 2>&1; then break; fi
  sleep 2
done

ALERT_COUNT="$(curl -sk -u "admin:${INDEXER_PASSWORD}" \
  "https://localhost:${OPENSEARCH_PORT_FWD_LOCAL}/wazuh-alerts-*/_count" \
  | jq -r '.count // 0' 2>/dev/null || echo "0")"

kill "${PF_PID2}" 2>/dev/null || true

log "  Current alert count: ${ALERT_COUNT}"
ALERT_BASELINE_FILE="$(dirname "$0")/wazuh-alert-baseline.txt"
echo "${ALERT_COUNT}" > "${ALERT_BASELINE_FILE}"
manifest_add "WAZUH_ALERT_COUNT_BASELINE=${ALERT_COUNT}"
manifest_add "ALERT_BASELINE_FILE=${ALERT_BASELINE_FILE}"
echo ""

# ---------------------------------------------------------------------------
# Upload the manifest itself to S3
# ---------------------------------------------------------------------------
MANIFEST_S3_PATH="s3://${BACKUP_BUCKET}/${BACKUP_PREFIX}/manifests/backup-manifest-${DATE}.txt"
log "=== Uploading backup manifest ==="

# Add EBS snapshot IDs to manifest
for entry in "${EBS_SNAPSHOT_IDS[@]+"${EBS_SNAPSHOT_IDS[@]}"}"; do
  manifest_add "EBS_SNAPSHOT_ENTRY=${entry}"
done
manifest_add "BACKUP_DATE=${DATE}"
manifest_add "AWS_ACCOUNT=${AWS_ACCOUNT_ID}"
manifest_add "REGION=${REGION}"

aws s3 cp "${MANIFEST_FILE}" "${MANIFEST_S3_PATH}" \
  --sse AES256 \
  --region "${REGION}" \
  || log "WARNING: Could not upload manifest to S3 — it is still at ${MANIFEST_FILE}"

log "  Manifest uploaded: ${MANIFEST_S3_PATH}"
echo ""

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------
echo "=============================================================="
echo "  PHASE 1 BACKUP COMPLETE"
echo "  Date: ${DATE}"
echo "  AWS Account: ${AWS_ACCOUNT_ID}"
echo "=============================================================="
echo ""
echo "  EBS Snapshots (async — verify in AWS Console):"
if [[ "${#EBS_SNAPSHOT_IDS[@]}" -gt 0 ]]; then
  for entry in "${EBS_SNAPSHOT_IDS[@]}"; do
    snap_id="${entry%%:*}"
    pvc_ref="${entry##*:}"
    echo "    ${snap_id}  ←  ${pvc_ref}"
  done
else
  echo "    (none)"
fi
echo ""
echo "  S3 Paths:"
for path in "${S3_PATHS[@]+"${S3_PATHS[@]}"}"; do
  echo "    ${path}"
done
echo ""
echo "  BACKUP MANIFEST (local): ${MANIFEST_FILE}"
echo "  BACKUP MANIFEST (S3):    ${MANIFEST_S3_PATH}"
echo ""
echo "  NEXT STEPS:"
echo "    1. Verify EBS snapshots reach 'completed' state in AWS Console"
echo "    2. Verify OpenSearch snapshot: repository=${OPENSEARCH_REPO_NAME}"
echo "    3. Store manifest S3 path for use in phase5-restore.sh"
echo "    4. Only proceed with Phase 2 (infrastructure) after all snapshots are confirmed"
echo "=============================================================="

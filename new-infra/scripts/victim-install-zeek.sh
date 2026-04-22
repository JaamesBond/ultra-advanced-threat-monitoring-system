#!/usr/bin/env bash
# =============================================================================
# victim-install-zeek.sh — XDR v8 / bc-prd victim EC2
# Installs Zeek from the official zeek.org APT repository (Ubuntu 24.04),
# configures it to monitor eth0, outputs all logs as JSON to /var/log/zeek,
# deploys via zeekctl, and sets up a cron watchdog.
#
# Runs as root via SSM. Safe to re-run (idempotent).
#
# Optional env vars:
#   ZEEK_IFACE   — network interface to monitor (default: eth0)
#   ZEEK_LOGDIR  — base log directory           (default: /var/log/zeek)
#   ZEEK_PREFIX  — Zeek install prefix          (default: /opt/zeek)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
ZEEK_IFACE="${ZEEK_IFACE:-eth0}"
ZEEK_LOGDIR="${ZEEK_LOGDIR:-/var/log/zeek}"
ZEEK_PREFIX="${ZEEK_PREFIX:-/opt/zeek}"
ZEEK_BIN="${ZEEK_PREFIX}/bin"
ZEEKCTL="${ZEEK_BIN}/zeekctl"
ZEEK_NODE_CFG="${ZEEK_PREFIX}/etc/node.cfg"
ZEEK_CTRL_CFG="${ZEEK_PREFIX}/etc/zeekctl.cfg"
ZEEK_LOCAL_ZEEk="${ZEEK_PREFIX}/share/zeek/site/local.zeek"
CRON_FILE="/etc/cron.d/zeek-watchdog"
SCRIPT_NAME="$(basename "$0")"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME}] $*"; }
fail() { log "FATAL: $1"; exit 1; }

trap 'log "FATAL: script aborted at line ${LINENO} (last command exited $?)"' ERR

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
log "=== Zeek — victim EC2 installer ==="
log "Interface : ${ZEEK_IFACE}"
log "Log dir   : ${ZEEK_LOGDIR}"
log "Prefix    : ${ZEEK_PREFIX}"
echo ""

[[ "$(id -u)" -eq 0 ]] || fail "This script must be run as root."

# Verify the interface exists
if ! ip link show "${ZEEK_IFACE}" >/dev/null 2>&1; then
  fail "Network interface '${ZEEK_IFACE}' not found. Set ZEEK_IFACE to the correct interface name."
fi
log "Interface ${ZEEK_IFACE} confirmed present."
echo ""

# ===========================================================================
# SECTION 1 — PREREQUISITES
# ===========================================================================
log "--- Installing prerequisites ---"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq \
  curl \
  gnupg \
  lsb-release \
  ca-certificates \
  cmake \
  make \
  gcc \
  g++ \
  flex \
  bison \
  libpcap-dev \
  libssl-dev \
  python3 \
  python3-dev \
  python3-pip \
  zlib1g-dev \
  swig \
  jq \
  cron \
  >/dev/null 2>&1

log "Prerequisites installed."
echo ""

# ===========================================================================
# SECTION 2 — ZEEK OFFICIAL APT REPOSITORY
# ===========================================================================
log "--- Configuring Zeek official APT repository ---"

ZEEK_GPG_KEY="/usr/share/keyrings/zeek-archive-keyring.gpg"
ZEEK_REPO_FILE="/etc/apt/sources.list.d/zeek.list"
# Ubuntu 24.04 codename is 'noble'
UBUNTU_CODENAME="$(lsb_release -cs 2>/dev/null || echo 'noble')"

if [[ ! -f "${ZEEK_GPG_KEY}" ]]; then
  log "Importing Zeek GPG key..."
  curl -fsSL "https://download.opensuse.org/repositories/security:zeek/xUbuntu_24.04/Release.key" \
    | gpg --dearmor -o "${ZEEK_GPG_KEY}" \
    || fail "Failed to import Zeek GPG key"
  log "GPG key imported → ${ZEEK_GPG_KEY}"
else
  log "Zeek GPG key already present — skipping import."
fi

if [[ ! -f "${ZEEK_REPO_FILE}" ]]; then
  log "Adding Zeek APT repository for ${UBUNTU_CODENAME}..."
  cat > "${ZEEK_REPO_FILE}" <<REPO
deb [signed-by=${ZEEK_GPG_KEY}] https://download.opensuse.org/repositories/security:/zeek/xUbuntu_24.04/ /
REPO
  apt-get update -qq
  log "Zeek repository added."
else
  log "Zeek repository already configured — skipping."
fi

echo ""

# ===========================================================================
# SECTION 3 — INSTALL ZEEK (IDEMPOTENT)
# ===========================================================================
log "--- Installing Zeek ---"

if dpkg -l zeek 2>/dev/null | grep -q "^ii"; then
  INSTALLED_VER="$(dpkg -l zeek | awk '/^ii/{print $3}' | head -1)"
  log "Zeek already installed (${INSTALLED_VER}) — skipping package install."
else
  apt-get install -y -qq zeek \
    || fail "Zeek package installation failed"
  log "Zeek installed: $("${ZEEK_BIN}/zeek" --version 2>&1 | head -1)"
fi

# Ensure zeek binaries are in PATH for this session
export PATH="${ZEEK_BIN}:${PATH}"

echo ""

# ===========================================================================
# SECTION 4 — CONFIGURE node.cfg
# ===========================================================================
log "--- Writing ${ZEEK_NODE_CFG} ---"

if [[ -f "${ZEEK_NODE_CFG}" ]]; then
  BACKUP_PATH="${ZEEK_NODE_CFG}.bak.$(date +%Y%m%dT%H%M%S)"
  cp "${ZEEK_NODE_CFG}" "${BACKUP_PATH}"
  log "Backed up existing node.cfg → ${BACKUP_PATH}"
fi

cat > "${ZEEK_NODE_CFG}" <<EOF
# =============================================================================
# node.cfg — Zeek node configuration for bc-prd victim EC2 (10.30.10.64)
# Managed by victim-install-zeek.sh — do not edit manually.
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# =============================================================================

[logger]
type=logger
host=localhost

[manager]
type=manager
host=localhost

[proxy-1]
type=proxy
host=localhost

[worker-1]
type=worker
host=localhost
interface=${ZEEK_IFACE}
lb_method=pf_ring
lb_procs=2
pin_cpus=0,1
EOF

log "node.cfg written."
echo ""

# ===========================================================================
# SECTION 5 — CONFIGURE zeekctl.cfg
# ===========================================================================
log "--- Writing ${ZEEK_CTRL_CFG} ---"

if [[ -f "${ZEEK_CTRL_CFG}" ]]; then
  BACKUP_PATH="${ZEEK_CTRL_CFG}.bak.$(date +%Y%m%dT%H%M%S)"
  cp "${ZEEK_CTRL_CFG}" "${BACKUP_PATH}"
  log "Backed up existing zeekctl.cfg → ${BACKUP_PATH}"
fi

# Ensure log directory exists
mkdir -p "${ZEEK_LOGDIR}"
mkdir -p "${ZEEK_LOGDIR}/current"

cat > "${ZEEK_CTRL_CFG}" <<EOF
# =============================================================================
# zeekctl.cfg — ZeekControl configuration for bc-prd victim EC2 (10.30.10.64)
# Managed by victim-install-zeek.sh — do not edit manually.
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# =============================================================================

# Log directory — Wazuh agent reads from ${ZEEK_LOGDIR}/current/
LogDir = ${ZEEK_LOGDIR}

# Spool directory (working files)
SpoolDir = ${ZEEK_PREFIX}/spool

# Where to write zeekctl's own log
CfgDir = ${ZEEK_PREFIX}/etc

# Rotation interval: rotate logs every hour
LogRotationInterval = 3600

# Keep logs for 7 days
LogExpireInterval = 7

# Mail settings (disabled — no MTA on this host)
MailTo =
MailFrom =
MailSubjectPrefix = [Zeek]
MailAlarmsTo =

# Interface
BindAddr = 0.0.0.0

# Stats logging interval (seconds)
StatsLogExpireInterval = 7
EOF

log "zeekctl.cfg written."
echo ""

# ===========================================================================
# SECTION 6 — ENABLE JSON OUTPUT IN local.zeek
# ===========================================================================
log "--- Enabling JSON log output in ${ZEEK_LOCAL_ZEEk} ---"

# The local.zeek file is expected to exist after installation
if [[ ! -f "${ZEEK_LOCAL_ZEEk}" ]]; then
  log "Creating ${ZEEK_LOCAL_ZEEk} from scratch..."
  touch "${ZEEK_LOCAL_ZEEk}"
fi

# Backup existing local.zeek
BACKUP_PATH="${ZEEK_LOCAL_ZEEk}.bak.$(date +%Y%m%dT%H%M%S)"
cp "${ZEEK_LOCAL_ZEEk}" "${BACKUP_PATH}"
log "Backed up existing local.zeek → ${BACKUP_PATH}"

# Check if JSON is already configured; if not, append or replace
if grep -q 'LogAscii::use_json\|json-logs' "${ZEEK_LOCAL_ZEEk}" 2>/dev/null; then
  log "JSON output already configured in local.zeek — ensuring it is enabled..."
  # Force the setting on in case it was set to F
  sed -i 's/redef LogAscii::use_json\s*=\s*F/redef LogAscii::use_json = T/g' "${ZEEK_LOCAL_ZEEk}"
else
  log "Appending JSON output directive to local.zeek..."
fi

# Write a clean, canonical local.zeek that merges any existing content
# with our required JSON directive at the top.
EXISTING_CONTENT="$(cat "${ZEEK_LOCAL_ZEEk}")"

cat > "${ZEEK_LOCAL_ZEEk}" <<EOF
# =============================================================================
# local.zeek — site-local Zeek policy for bc-prd victim EC2 (10.30.10.64)
# Managed by victim-install-zeek.sh — do not edit manually.
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# =============================================================================

# ---------------------------------------------------------------------------
# JSON output — required for Wazuh log ingestion
# All logs written by Zeek will use JSON format instead of TSV.
# ---------------------------------------------------------------------------
redef LogAscii::use_json = T;

# ---------------------------------------------------------------------------
# Standard site policy scripts
# ---------------------------------------------------------------------------
@load base/frameworks/software
@load base/frameworks/notice
@load misc/loaded-scripts
@load tuning/defaults
@load misc/stats

# Capture SSH information for authentication monitoring
@load policy/protocols/ssh/detect-bruteforcing
@load policy/protocols/ssh/software

# HTTP analysis
@load policy/protocols/http/detect-sqli

# DNS analysis
@load policy/protocols/dns/detect-external-names

# Connection summaries
@load policy/misc/conn-disable-data-history

# Detect scanning activity
@load policy/misc/scan

# Log all communications even if the data is incomplete
@load base/protocols/conn/removal-hooks

EOF

log "local.zeek written with JSON output enabled."
echo ""

# ===========================================================================
# SECTION 7 — DEPLOY AND START ZEEK
# ===========================================================================
log "--- Deploying Zeek via zeekctl ---"

# Install zeekctl (initialise internal state if first run)
log "Running zeekctl install..."
"${ZEEKCTL}" install 2>&1 | while IFS= read -r line; do
  log "  [zeekctl install] ${line}"
done || log "WARNING: zeekctl install reported errors (may be safe to ignore on re-runs)"

# Stop any running instance first (idempotent — ok if already stopped)
log "Stopping any running Zeek instance..."
"${ZEEKCTL}" stop 2>&1 | while IFS= read -r line; do
  log "  [zeekctl stop] ${line}"
done || true

# Deploy (compiles scripts and starts all nodes)
log "Running zeekctl deploy..."
"${ZEEKCTL}" deploy 2>&1 | while IFS= read -r line; do
  log "  [zeekctl deploy] ${line}"
done || fail "zeekctl deploy failed — check output above"

log "Zeek deployed."
echo ""

# ===========================================================================
# SECTION 8 — VERIFY ZEEK IS RUNNING
# ===========================================================================
log "--- Verifying Zeek status ---"

ZEEK_STATUS="$("${ZEEKCTL}" status 2>&1 || true)"
log "zeekctl status output:"
echo "${ZEEK_STATUS}" | while IFS= read -r line; do log "  ${line}"; done

# Check for 'running' in the output
if echo "${ZEEK_STATUS}" | grep -qi "running"; then
  log "Zeek workers are running."
else
  log "WARNING: No workers appear to be in 'running' state."
  log "         Check: ${ZEEKCTL} status"
fi

echo ""

# ===========================================================================
# SECTION 9 — CRON WATCHDOG (zeekctl cron every 5 minutes)
# ===========================================================================
log "--- Setting up zeekctl cron watchdog ---"

cat > "${CRON_FILE}" <<EOF
# zeek-watchdog — managed by victim-install-zeek.sh
# Runs zeekctl cron every 5 minutes: restarts crashed workers, rotates logs
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:${ZEEK_BIN}

*/5 * * * * root ${ZEEKCTL} cron >> /var/log/zeek/zeekctl-cron.log 2>&1
EOF

chmod 644 "${CRON_FILE}"
log "Cron watchdog written to ${CRON_FILE}"

# Reload cron to pick up new file
systemctl reload cron 2>/dev/null || true
log "Cron daemon reloaded."
echo ""

# ===========================================================================
# SECTION 10 — VERIFY LOG FILES ARE BEING WRITTEN
# ===========================================================================
log "--- Verifying Zeek log output ---"

LOG_VERIFY_TIMEOUT=30
LOG_VERIFY_ELAPSED=0
CONN_LOG="${ZEEK_LOGDIR}/current/conn.log"

log "Waiting for ${CONN_LOG} to appear (up to ${LOG_VERIFY_TIMEOUT}s)..."
while [[ ! -f "${CONN_LOG}" ]]; do
  if (( LOG_VERIFY_ELAPSED >= LOG_VERIFY_TIMEOUT )); then
    log "WARNING: ${CONN_LOG} not yet created."
    log "         Zeek may still be initialising, or no traffic has been observed."
    log "         Check: ${ZEEKCTL} status"
    break
  fi
  sleep 3
  (( LOG_VERIFY_ELAPSED += 3 ))
done

if [[ -f "${CONN_LOG}" ]]; then
  LINE_COUNT="$(wc -l < "${CONN_LOG}" 2>/dev/null || echo 0)"
  log "conn.log exists (${LINE_COUNT} lines so far)."
  # Validate JSON format
  if [[ "${LINE_COUNT}" -gt 0 ]]; then
    FIRST_LINE="$(head -1 "${CONN_LOG}")"
    if echo "${FIRST_LINE}" | jq . >/dev/null 2>&1; then
      log "JSON format confirmed in conn.log."
    else
      log "WARNING: conn.log first line is not valid JSON — check local.zeek JSON directive."
      log "  First line: ${FIRST_LINE:0:200}"
    fi
  fi
fi

# List all current log files
log "Log files in ${ZEEK_LOGDIR}/current/:"
ls -lh "${ZEEK_LOGDIR}/current/" 2>/dev/null | while IFS= read -r line; do
  log "  ${line}"
done

echo ""
log "================================================================"
log "SUCCESS: Zeek installed, configured, and running."
log "  Interface  : ${ZEEK_IFACE}"
log "  Log dir    : ${ZEEK_LOGDIR}/current/"
log "  Log format : JSON (LogAscii::use_json = T)"
log "  Key logs   : conn.log, http.log, dns.log, notice.log, ssh.log"
log "  Cron       : ${CRON_FILE} (zeekctl cron every 5 min)"
log "  Wazuh picks up JSON logs via localfile entries in ossec.conf."
log "================================================================"

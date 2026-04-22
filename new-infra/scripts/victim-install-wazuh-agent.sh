#!/usr/bin/env bash
# =============================================================================
# victim-install-wazuh-agent.sh — XDR v8 / bc-prd victim EC2
# Installs and configures the Wazuh 4.9.2 agent on an Ubuntu 24.04 host,
# registers it to the Wazuh manager, and writes a full ossec.conf with all
# relevant log sources (auth, syslog, dpkg, Suricata EVE, Zeek logs).
#
# Runs as root via SSM. Safe to re-run (idempotent).
#
# Optional env vars:
#   WAZUH_MANAGER   — Wazuh manager private IP  (default: 10.0.10.208)
#   WAZUH_VERSION   — Package version to pin     (default: 4.9.2-1)
#
# KNOWN ISSUES:
#   - journald collector is broken on Ubuntu 24.04 — auth/syslog are read
#     directly from /var/log files using syslog format, NOT journald.
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
WAZUH_MANAGER="${WAZUH_MANAGER:-10.0.10.208}"
WAZUH_MANAGER_PORT="${WAZUH_MANAGER_PORT:-1514}"
WAZUH_PROTOCOL="${WAZUH_PROTOCOL:-tcp}"
WAZUH_VERSION="${WAZUH_VERSION:-4.9.2-1}"
OSSEC_CONF="/var/ossec/etc/ossec.conf"
SCRIPT_NAME="$(basename "$0")"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME}] $*"; }
fail() { log "FATAL: $1"; exit 1; }

trap 'log "FATAL: script aborted at line ${LINENO} (last command exited $?)"' ERR

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
log "=== Wazuh Agent ${WAZUH_VERSION} — victim EC2 installer ==="
log "Target manager: ${WAZUH_MANAGER}:${WAZUH_MANAGER_PORT} (${WAZUH_PROTOCOL})"
echo ""

[[ "$(id -u)" -eq 0 ]] || fail "This script must be run as root."

# ===========================================================================
# SECTION 1 — PREREQUISITES
# ===========================================================================
log "--- Installing prerequisites ---"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq \
  curl \
  gnupg \
  apt-transport-https \
  lsb-release \
  ca-certificates \
  jq \
  >/dev/null 2>&1

log "Prerequisites installed."
echo ""

# ===========================================================================
# SECTION 2 — WAZUH APT REPOSITORY
# ===========================================================================
log "--- Configuring Wazuh APT repository (4.x) ---"

WAZUH_GPG_KEY="/usr/share/keyrings/wazuh.gpg"
WAZUH_REPO_FILE="/etc/apt/sources.list.d/wazuh.list"

if [[ ! -f "${WAZUH_GPG_KEY}" ]]; then
  log "Importing Wazuh GPG key..."
  curl -fsSL "https://packages.wazuh.com/key/GPG-KEY-WAZUH" \
    | gpg --dearmor -o "${WAZUH_GPG_KEY}" \
    || fail "Failed to import Wazuh GPG key"
  log "GPG key imported → ${WAZUH_GPG_KEY}"
else
  log "Wazuh GPG key already present — skipping import."
fi

if [[ ! -f "${WAZUH_REPO_FILE}" ]]; then
  log "Adding Wazuh APT repository..."
  echo "deb [signed-by=${WAZUH_GPG_KEY}] https://packages.wazuh.com/4.x/apt/ stable main" \
    > "${WAZUH_REPO_FILE}"
  apt-get update -qq
  log "Wazuh repository added."
else
  log "Wazuh repository already configured — skipping."
fi

echo ""

# ===========================================================================
# SECTION 3 — INSTALL WAZUH AGENT (IDEMPOTENT)
# ===========================================================================
log "--- Installing wazuh-agent ${WAZUH_VERSION} ---"

PKG_INSTALLED=false
if dpkg -l wazuh-agent 2>/dev/null | grep -q "^ii"; then
  INSTALLED_VER="$(dpkg -l wazuh-agent | awk '/^ii/{print $3}' | head -1)"
  log "wazuh-agent is already installed (${INSTALLED_VER}) — skipping package install."
  PKG_INSTALLED=true
else
  log "Installing wazuh-agent package..."
  # Register manager before installation so the package pre-seeds it
  WAZUH_MANAGER="${WAZUH_MANAGER}" \
  WAZUH_MANAGER_PORT="${WAZUH_MANAGER_PORT}" \
  apt-get install -y -qq "wazuh-agent=${WAZUH_VERSION}" \
    || fail "wazuh-agent package installation failed (version=${WAZUH_VERSION})"
  log "wazuh-agent ${WAZUH_VERSION} installed."
  PKG_INSTALLED=true
fi

echo ""

# ===========================================================================
# SECTION 4 — WRITE OSSEC.CONF
# ===========================================================================
log "--- Writing ${OSSEC_CONF} ---"

# Back up existing config if present
if [[ -f "${OSSEC_CONF}" ]]; then
  BACKUP_PATH="${OSSEC_CONF}.bak.$(date +%Y%m%dT%H%M%S)"
  cp "${OSSEC_CONF}" "${BACKUP_PATH}"
  log "Backed up existing ossec.conf → ${BACKUP_PATH}"
fi

cat > "${OSSEC_CONF}" <<EOF
<!--
  ossec.conf — Wazuh agent config for bc-prd victim EC2 (10.30.10.64)
  Managed by victim-install-wazuh-agent.sh — do not edit manually.
  Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
-->
<ossec_config>

  <!-- ====================================================
       CLIENT — manager registration
       ==================================================== -->
  <client>
    <server>
      <address>${WAZUH_MANAGER}</address>
      <port>${WAZUH_MANAGER_PORT}</port>
      <protocol>${WAZUH_PROTOCOL}</protocol>
    </server>
    <config-profile>ubuntu, ubuntu24</config-profile>
    <notify_time>60</notify_time>
    <time-reconnect>300</time-reconnect>
    <auto_restart>yes</auto_restart>
    <crypto_method>aes</crypto_method>
  </client>

  <!-- ====================================================
       CLIENT BUFFER
       ==================================================== -->
  <client_buffer>
    <disabled>no</disabled>
    <queue_size>5000</queue_size>
    <events_per_second>500</events_per_second>
  </client_buffer>

  <!-- ====================================================
       LOGGING — agent-side log level
       ==================================================== -->
  <logging>
    <log_format>plain</log_format>
  </logging>

  <!-- ====================================================
       ROOTCHECK
       ==================================================== -->
  <rootcheck>
    <disabled>no</disabled>
    <check_files>yes</check_files>
    <check_trojans>yes</check_trojans>
    <check_dev>yes</check_dev>
    <check_sys>yes</check_sys>
    <check_pids>yes</check_pids>
    <check_ports>yes</check_ports>
    <check_if>yes</check_if>
    <frequency>43200</frequency>
    <rootkit_files>/var/ossec/etc/shared/rootkit_files.txt</rootkit_files>
    <rootkit_trojans>/var/ossec/etc/shared/rootkit_trojans.txt</rootkit_trojans>
    <skip_nfs>yes</skip_nfs>
  </rootcheck>

  <!-- ====================================================
       SCA — Security Configuration Assessment
       ==================================================== -->
  <sca>
    <enabled>yes</enabled>
    <scan_on_start>yes</scan_on_start>
    <interval>12h</interval>
    <skip_nfs>yes</skip_nfs>
  </sca>

  <!-- ====================================================
       VULNERABILITY DETECTOR
       ==================================================== -->
  <vulnerability-detection>
    <enabled>yes</enabled>
    <index-status>yes</index-status>
    <feed-update-interval>60m</feed-update-interval>
  </vulnerability-detection>

  <!-- ====================================================
       FILE INTEGRITY MONITORING
       ==================================================== -->
  <syscheck>
    <disabled>no</disabled>
    <frequency>43200</frequency>
    <scan_on_start>yes</scan_on_start>
    <alert_new_files>yes</alert_new_files>
    <auto_ignore frequency="10" timeframe="3600">no</auto_ignore>

    <!-- Critical system dirs -->
    <directories check_all="yes" report_changes="yes" realtime="yes">/etc,/usr/bin,/usr/sbin</directories>
    <directories check_all="yes" report_changes="yes" realtime="yes">/bin,/sbin</directories>
    <directories check_all="yes">/boot</directories>

    <!-- Ignore volatile paths -->
    <ignore>/etc/mtab</ignore>
    <ignore>/etc/hosts.deny</ignore>
    <ignore>/etc/mail/statistics</ignore>
    <ignore>/etc/random-seed</ignore>
    <ignore>/etc/adjtime</ignore>
    <ignore>/etc/httpd/logs</ignore>
    <ignore>/etc/utmpx</ignore>
    <ignore>/etc/wtmpx</ignore>
    <ignore>/etc/cups/certs</ignore>
    <ignore>/etc/dumpdates</ignore>
    <ignore>/etc/svc/volatile</ignore>
    <ignore type="sregex">.log$|.swp$</ignore>

    <nodiff>/etc/ssl/private.key</nodiff>
    <skip_nfs>yes</skip_nfs>
    <skip_dev>yes</skip_dev>
    <skip_proc>yes</skip_proc>
    <skip_sys>yes</skip_sys>
    <process_priority>10</process_priority>
    <max_eps>100</max_eps>
  </syscheck>

  <!-- ====================================================
       ACTIVE RESPONSE (disabled — monitoring only)
       ==================================================== -->
  <active-response>
    <disabled>yes</disabled>
  </active-response>

  <!-- ====================================================
       LOG ANALYSIS — LOCAL FILES
       NOTE: journald collector is broken on Ubuntu 24.04.
             All sources use flat-file / syslog format.
       ==================================================== -->

  <!-- /var/log/auth.log — SSH brute force, sudo, PAM events -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/auth.log</location>
  </localfile>

  <!-- /var/log/syslog — kernel and system messages -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/syslog</location>
  </localfile>

  <!-- /var/log/dpkg.log — package installs/removals (supply-chain monitoring) -->
  <localfile>
    <log_format>syslog</log_format>
    <location>/var/log/dpkg.log</location>
  </localfile>

  <!-- /var/log/suricata/eve.json — IDS alerts, http, dns, tls, flow, ssh -->
  <!-- Only monitored if Suricata is installed and producing logs           -->
  <localfile>
    <log_format>json</log_format>
    <location>/var/log/suricata/eve.json</location>
    <only-future-events>no</only-future-events>
  </localfile>

  <!-- Zeek conn.log — network connection metadata -->
  <localfile>
    <log_format>json</log_format>
    <location>/var/log/zeek/current/conn.log</location>
    <only-future-events>no</only-future-events>
  </localfile>

  <!-- Zeek http.log — HTTP request/response metadata -->
  <localfile>
    <log_format>json</log_format>
    <location>/var/log/zeek/current/http.log</location>
    <only-future-events>no</only-future-events>
  </localfile>

  <!-- Zeek dns.log — DNS queries and responses -->
  <localfile>
    <log_format>json</log_format>
    <location>/var/log/zeek/current/dns.log</location>
    <only-future-events>no</only-future-events>
  </localfile>

  <!-- Zeek notice.log — policy-generated notices (e.g. port scans) -->
  <localfile>
    <log_format>json</log_format>
    <location>/var/log/zeek/current/notice.log</location>
    <only-future-events>no</only-future-events>
  </localfile>

  <!-- ====================================================
       SYSCOLLECTOR — hardware / software inventory
       ==================================================== -->
  <wodle name="syscollector">
    <disabled>no</disabled>
    <interval>1h</interval>
    <scan_on_start>yes</scan_on_start>
    <hardware>yes</hardware>
    <os>yes</os>
    <network>yes</network>
    <packages>yes</packages>
    <ports all="no">yes</ports>
    <processes>yes</processes>
  </wodle>

  <!-- ====================================================
       AGENT LABELS — for dashboard filtering
       ==================================================== -->
  <labels>
    <label key="aws.instance-id">i-0dcc10fe9735f8534</label>
    <label key="aws.vpc">bc-prd</label>
    <label key="role">victim</label>
    <label key="environment">prd</label>
  </labels>

</ossec_config>
EOF

chown root:wazuh "${OSSEC_CONF}"
chmod 640 "${OSSEC_CONF}"
log "ossec.conf written successfully."
echo ""

# ===========================================================================
# SECTION 5 — REGISTER AGENT TO MANAGER
# ===========================================================================
log "--- Registering agent to manager at ${WAZUH_MANAGER} ---"

# The agent registers automatically on first start when WAZUH_MANAGER is set
# in the config. We also ensure the environment variable is set in the
# systemd service override so it survives reboots.
SYSTEMD_OVERRIDE_DIR="/etc/systemd/system/wazuh-agent.service.d"
mkdir -p "${SYSTEMD_OVERRIDE_DIR}"

cat > "${SYSTEMD_OVERRIDE_DIR}/manager.conf" <<EOF
[Service]
Environment="WAZUH_MANAGER=${WAZUH_MANAGER}"
Environment="WAZUH_MANAGER_PORT=${WAZUH_MANAGER_PORT}"
EOF

systemctl daemon-reload
log "systemd override written for wazuh-agent."
echo ""

# ===========================================================================
# SECTION 6 — ENABLE AND START WAZUH AGENT
# ===========================================================================
log "--- Enabling and starting wazuh-agent ---"

systemctl enable wazuh-agent
systemctl restart wazuh-agent

# Give the agent a moment to connect
sleep 5

if systemctl is-active --quiet wazuh-agent; then
  log "wazuh-agent is running."
else
  log "WARNING: wazuh-agent is not active — checking journal for errors..."
  journalctl -u wazuh-agent --no-pager -n 30 || true
  fail "wazuh-agent failed to start."
fi

echo ""

# ===========================================================================
# SECTION 7 — REGISTRATION CONFIRMATION
# ===========================================================================
log "--- Registration confirmation ---"

# Show the agent's registration state from the local client state file
AGENT_STATE_FILE="/var/ossec/var/run/wazuh-agentd.state"
if [[ -f "${AGENT_STATE_FILE}" ]]; then
  STATUS_LINE="$(grep -E '^status=' "${AGENT_STATE_FILE}" 2>/dev/null || echo 'status=unknown')"
  log "Agent state: ${STATUS_LINE}"
else
  log "Agent state file not yet created — agent may still be connecting."
fi

# Show last 10 lines of ossec.log for connection confirmation
log "Recent ossec.log output:"
tail -10 /var/ossec/logs/ossec.log 2>/dev/null | while IFS= read -r line; do
  log "  ${line}"
done

echo ""
log "================================================================"
log "SUCCESS: Wazuh agent ${WAZUH_VERSION} installed and started."
log "  Manager : ${WAZUH_MANAGER}:${WAZUH_MANAGER_PORT} (${WAZUH_PROTOCOL})"
log "  ossec.conf: ${OSSEC_CONF}"
log "  Log sources:"
log "    /var/log/auth.log        (syslog)"
log "    /var/log/syslog          (syslog)"
log "    /var/log/dpkg.log        (syslog)"
log "    /var/log/suricata/eve.json   (json — if present)"
log "    /var/log/zeek/current/*.log  (json — if present)"
log "================================================================"

#!/usr/bin/env bash
# =============================================================================
# victim-install-suricata.sh — XDR v8 / bc-prd victim EC2
# Installs Suricata (latest stable via Ubuntu 24.04 PPA), configures af-packet
# capture on eth0, enables EVE JSON output, downloads ET Open rules, and
# starts the service.
#
# Runs as root via SSM. Safe to re-run (idempotent).
#
# Optional env vars:
#   SURICATA_IFACE  — network interface to monitor (default: eth0)
#   SURICATA_LOGDIR — EVE JSON log directory       (default: /var/log/suricata)
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------
SURICATA_IFACE="${SURICATA_IFACE:-eth0}"
SURICATA_LOGDIR="${SURICATA_LOGDIR:-/var/log/suricata}"
SURICATA_YAML="/etc/suricata/suricata.yaml"
SURICATA_EVE_JSON="${SURICATA_LOGDIR}/eve.json"
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
log "=== Suricata — victim EC2 installer ==="
log "Interface : ${SURICATA_IFACE}"
log "Log dir   : ${SURICATA_LOGDIR}"
echo ""

[[ "$(id -u)" -eq 0 ]] || fail "This script must be run as root."

# Verify the interface exists
if ! ip link show "${SURICATA_IFACE}" >/dev/null 2>&1; then
  fail "Network interface '${SURICATA_IFACE}' not found. Set SURICATA_IFACE to the correct interface name."
fi
log "Interface ${SURICATA_IFACE} confirmed present."
echo ""

# ===========================================================================
# SECTION 1 — PREREQUISITES
# ===========================================================================
log "--- Installing prerequisites ---"

export DEBIAN_FRONTEND=noninteractive

apt-get update -qq
apt-get install -y -qq \
  software-properties-common \
  curl \
  gnupg \
  lsb-release \
  ca-certificates \
  jq \
  python3-pip \
  >/dev/null 2>&1

log "Prerequisites installed."
echo ""

# ===========================================================================
# SECTION 2 — SURICATA PPA AND PACKAGE INSTALL (IDEMPOTENT)
# ===========================================================================
log "--- Configuring Suricata PPA (oisf/suricata-stable) ---"

if ! apt-cache policy 2>/dev/null | grep -q "suricata-stable"; then
  add-apt-repository -y ppa:oisf/suricata-stable >/dev/null 2>&1
  apt-get update -qq
  log "Suricata PPA added."
else
  log "Suricata PPA already configured — skipping."
fi

echo ""
log "--- Installing Suricata ---"

if dpkg -l suricata 2>/dev/null | grep -q "^ii"; then
  INSTALLED_VER="$(dpkg -l suricata | awk '/^ii/{print $3}' | head -1)"
  log "Suricata already installed (${INSTALLED_VER}) — skipping package install."
else
  apt-get install -y -qq suricata \
    || fail "Suricata package installation failed"
  log "Suricata installed: $(suricata --build-info | grep 'Version' | head -1 | awk '{print $NF}')"
fi

echo ""

# ===========================================================================
# SECTION 3 — SURICATA CONFIGURATION
# ===========================================================================
log "--- Writing ${SURICATA_YAML} ---"

# Back up the existing config
if [[ -f "${SURICATA_YAML}" ]]; then
  BACKUP_PATH="${SURICATA_YAML}.bak.$(date +%Y%m%dT%H%M%S)"
  cp "${SURICATA_YAML}" "${BACKUP_PATH}"
  log "Backed up existing suricata.yaml → ${BACKUP_PATH}"
fi

# Ensure log directory exists with correct permissions
mkdir -p "${SURICATA_LOGDIR}"
chown suricata:suricata "${SURICATA_LOGDIR}" 2>/dev/null || chown root:root "${SURICATA_LOGDIR}"
chmod 755 "${SURICATA_LOGDIR}"

cat > "${SURICATA_YAML}" <<EOF
%YAML 1.1
---
# =============================================================================
# suricata.yaml — XDR v8 bc-prd victim EC2 (10.30.10.64)
# Managed by victim-install-suricata.sh — do not edit manually.
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
# =============================================================================

vars:
  address-groups:
    HOME_NET: "[10.0.0.0/8,172.16.0.0/12,192.168.0.0/16]"
    EXTERNAL_NET: "!\$HOME_NET"
    HTTP_SERVERS: "\$HOME_NET"
    SMTP_SERVERS: "\$HOME_NET"
    SQL_SERVERS: "\$HOME_NET"
    DNS_SERVERS: "\$HOME_NET"
    TELNET_SERVERS: "\$HOME_NET"
    AIM_SERVERS: "\$EXTERNAL_NET"
    DC_SERVERS: "\$HOME_NET"
    DNP3_SERVER: "\$HOME_NET"
    DNP3_CLIENT: "\$HOME_NET"
    MODBUS_CLIENT: "\$HOME_NET"
    MODBUS_SERVER: "\$HOME_NET"
    ENIP_CLIENT: "\$HOME_NET"
    ENIP_SERVER: "\$HOME_NET"

  port-groups:
    HTTP_PORTS: "80"
    SHELLCODE_PORTS: "!80"
    ORACLE_PORTS: 1521
    SSH_PORTS: 22
    DNP3_PORTS: 20000
    MODBUS_PORTS: 502
    FILE_DATA_PORTS: "[\$HTTP_PORTS,110,143]"
    FTP_PORTS: 21
    GENEVE_PORTS: 6081
    VXLAN_PORTS: 4789
    TEREDO_PORTS: 3544

# ---------------------------------------------------------------------------
# AF-PACKET capture — low-overhead kernel bypass on ${SURICATA_IFACE}
# ---------------------------------------------------------------------------
af-packet:
  - interface: ${SURICATA_IFACE}
    threads: auto
    cluster-id: 99
    cluster-type: cluster_flow
    defrag: yes
    use-mmap: yes
    mmap-locked: yes
    tpacket-v3: yes
    ring-size: 2048
    block-size: 32768
    block-timeout: 10
    use-emergency-flush: yes
    buffer-size: 32768
    rollover: yes
    checksum-checks: kernel
    copy-mode: none

# ---------------------------------------------------------------------------
# Run mode
# ---------------------------------------------------------------------------
runmode: autofp

default-packet-size: 1514

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------
outputs:
  # EVE unified JSON log — primary output consumed by Wazuh agent
  - eve-log:
      enabled: yes
      filetype: regular
      filename: ${SURICATA_EVE_JSON}
      community-id: true
      community-id-seed: 0
      xff:
        enabled: no
      types:
        - alert:
            payload: yes
            payload-buffer-size: 4kb
            payload-printable: yes
            packet: yes
            metadata: yes
            http-body: yes
            http-body-printable: yes
            tagged-packets: yes
        - http:
            extended: yes
        - dns:
            version: 2
            requests: yes
            responses: yes
        - tls:
            extended: yes
            session-resumption: no
        - flow:
            # Log flows at end of connection
        - ssh
        - stats:
            totals: yes
            threads: no
            deltas: no
            enabled: yes
        - dhcp:
            enabled: yes
            extended: yes

  # Fast log (human-readable alerts for quick triage)
  - fast:
      enabled: yes
      filename: /var/log/suricata/fast.log
      append: yes

  # Stats log
  - stats:
      enabled: yes
      filename: /var/log/suricata/stats.log
      append: yes
      totals: yes
      threads: no
      null-values: no

# ---------------------------------------------------------------------------
# Logging (Suricata internal log, NOT the traffic log)
# ---------------------------------------------------------------------------
logging:
  default-log-level: notice
  outputs:
    - console:
        enabled: yes
    - file:
        enabled: yes
        level: info
        filename: /var/log/suricata/suricata.log

# ---------------------------------------------------------------------------
# Rule files
# ---------------------------------------------------------------------------
default-rule-path: /var/lib/suricata/rules

rule-files:
  - suricata.rules

# ---------------------------------------------------------------------------
# App layer protocol detection
# ---------------------------------------------------------------------------
app-layer:
  protocols:
    tls:
      enabled: yes
      detection-ports:
        dp: 443
    http:
      enabled: yes
      libhtp:
        default-config:
          personality: IDS
          request-body-limit: 100kb
          response-body-limit: 100kb
          request-body-minimal-inspect-size: 32kb
          request-body-inspect-window: 4kb
          response-body-minimal-inspect-size: 40kb
          response-body-inspect-window: 16kb
          response-body-decompress-layer-limit: 2
          http-body-inline: auto
          swf-decompression:
            enabled: yes
            type: both
            compress-depth: 100kb
            decompress-depth: 100kb
    ftp:
      enabled: yes
      memcap: 64mb
    smtp:
      enabled: yes
      raw-extraction: no
    imap:
      enabled: detection-only
    ssh:
      enabled: yes
      hassh: yes
    dns:
      global-memcap: 16mb
      state-memcap: 512kb
      request-flood: 500
      tcp:
        enabled: yes
        detection-ports:
          dp: 53
      udp:
        enabled: yes
        detection-ports:
          dp: 53

# ---------------------------------------------------------------------------
# Flow / Stream settings
# ---------------------------------------------------------------------------
flow:
  memcap: 128mb
  hash-size: 65536
  prealloc: 10000
  emergency-recovery: 30
  prune-flows: 5

vlan:
  use-for-tracking: true

stream:
  memcap: 64mb
  checksum-validation: yes
  inline: no
  reassembly:
    memcap: 256mb
    depth: 1mb
    toserver-chunk-size: 2560
    toclient-chunk-size: 2560
    randomize-chunk-size: yes

# ---------------------------------------------------------------------------
# Detection engine
# ---------------------------------------------------------------------------
detect:
  profile: medium
  custom-values:
    toclient-groups: 3
    toserver-groups: 25
  sgh-mpm-context: auto
  inspection-recursion-limit: 3000

# ---------------------------------------------------------------------------
# Threading
# ---------------------------------------------------------------------------
threading:
  set-cpu-affinity: no
  cpu-affinity:
    - management-cpu-set:
        cpu: [ 0 ]
    - receive-cpu-set:
        cpu: [ 0 ]
    - worker-cpu-set:
        cpu: [ "all" ]
        mode: "balanced"
        prio:
          default: "normal"
  detect-thread-ratio: 1.0

# ---------------------------------------------------------------------------
# File extraction
# ---------------------------------------------------------------------------
file-store:
  version: 2
  enabled: no

# ---------------------------------------------------------------------------
# Host table
# ---------------------------------------------------------------------------
host:
  hash-size: 4096
  prealloc: 1000
  memcap: 32mb
EOF

chown root:suricata "${SURICATA_YAML}" 2>/dev/null || chown root:root "${SURICATA_YAML}"
chmod 640 "${SURICATA_YAML}"
log "suricata.yaml written."
echo ""

# ===========================================================================
# SECTION 4 — WRITE SYSTEMD DEFAULTS (interface, runmode)
# ===========================================================================
log "--- Configuring /etc/default/suricata ---"

cat > /etc/default/suricata <<EOF
# /etc/default/suricata — managed by victim-install-suricata.sh
# Interface to capture on
IFACE="${SURICATA_IFACE}"
# Suricata run options — use af-packet, read config from standard path
SURARGS="-c ${SURICATA_YAML} --af-packet=${SURICATA_IFACE}"
EOF

log "/etc/default/suricata written."
echo ""

# ===========================================================================
# SECTION 5 — DOWNLOAD / UPDATE ET OPEN RULES
# ===========================================================================
log "--- Updating Suricata rules via suricata-update ---"

# suricata-update ships with Suricata 6+ on Ubuntu PPA
if ! command -v suricata-update >/dev/null 2>&1; then
  log "suricata-update not found — installing via pip..."
  pip3 install --quiet suricata-update \
    || fail "Failed to install suricata-update"
fi

log "Running suricata-update (ET Open ruleset)..."
suricata-update --no-reload \
  2>&1 | while IFS= read -r line; do log "  [suricata-update] ${line}"; done

log "Rules updated."
echo ""

# ===========================================================================
# SECTION 6 — VALIDATE CONFIG
# ===========================================================================
log "--- Validating Suricata configuration ---"
suricata -T -c "${SURICATA_YAML}" --af-packet="${SURICATA_IFACE}" 2>&1 \
  | while IFS= read -r line; do log "  [suricata-test] ${line}"; done
log "Configuration validation passed."
echo ""

# ===========================================================================
# SECTION 7 — ENABLE AND START SURICATA
# ===========================================================================
log "--- Enabling and starting Suricata service ---"

systemctl enable suricata
systemctl restart suricata

# Wait for Suricata to initialise (rules load can take ~10s)
TIMEOUT=60
ELAPSED=0
while ! systemctl is-active --quiet suricata; do
  if (( ELAPSED >= TIMEOUT )); then
    log "WARNING: Suricata did not become active within ${TIMEOUT}s — dumping journal..."
    journalctl -u suricata --no-pager -n 40 || true
    fail "Suricata failed to start."
  fi
  sleep 3
  (( ELAPSED += 3 ))
done

log "Suricata service is active."
echo ""

# ===========================================================================
# SECTION 8 — VERIFY EVE JSON IS BEING WRITTEN
# ===========================================================================
log "--- Verifying EVE JSON output ---"

# Give Suricata up to 30 s to create and write to eve.json
EVE_TIMEOUT=30
EVE_ELAPSED=0
while [[ ! -s "${SURICATA_EVE_JSON}" ]]; do
  if (( EVE_ELAPSED >= EVE_TIMEOUT )); then
    log "WARNING: ${SURICATA_EVE_JSON} not yet populated (this is normal if no traffic has been seen)."
    log "         Suricata is running; logs will appear once traffic is observed."
    break
  fi
  sleep 2
  (( EVE_ELAPSED += 2 ))
done

if [[ -s "${SURICATA_EVE_JSON}" ]]; then
  FIRST_EVENT="$(head -1 "${SURICATA_EVE_JSON}" | jq -r '.event_type' 2>/dev/null || echo 'unknown')"
  log "EVE JSON is being written. First event type: ${FIRST_EVENT}"
fi

echo ""
log "================================================================"
log "SUCCESS: Suricata installed, configured, and running."
log "  Interface  : ${SURICATA_IFACE} (af-packet)"
log "  EVE JSON   : ${SURICATA_EVE_JSON}"
log "  Fast log   : /var/log/suricata/fast.log"
log "  Rules      : /var/lib/suricata/rules/suricata.rules (ET Open)"
log "  Community-ID: enabled (seed=0)"
log "  Wazuh will pick up EVE JSON via localfile in ossec.conf."
log "================================================================"

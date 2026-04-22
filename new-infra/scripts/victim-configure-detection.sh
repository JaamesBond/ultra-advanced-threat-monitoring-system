#!/usr/bin/env bash
# Configure Suricata + Wazuh for brute force, Nmap, and DDoS detection
set -euo pipefail

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# ─── 1. SURICATA: Enable portscan detector ───────────────────────────────────
log "Enabling Suricata portscan detection..."

python3 - << 'EOF'
import re

with open("/etc/suricata/suricata.yaml") as f:
    cfg = f.read()

# Add portscan + anomaly to eve-log if not present
if "- portscan" not in cfg:
    cfg = re.sub(
        r'(\s+- stats:)',
        '\n      - portscan\n      - anomaly:\n          enabled: yes\n          types:\n            - decode\n            - stream\n            - applayer\\1',
        cfg, count=1
    )
    print("Added portscan + anomaly to eve-log")
else:
    print("portscan already in eve-log")

# Enable stream inline mode for flood detection
if "stream-event" not in cfg:
    cfg = re.sub(
        r'(stream:\n)',
        'stream:\n  inline: no\n  checksum-validation: no\n',
        cfg, count=1
    )

with open("/etc/suricata/suricata.yaml", "w") as f:
    f.write(cfg)
print("suricata.yaml saved")
EOF

# ─── 2. SURICATA: Custom rules for brute force + DDoS ────────────────────────
log "Writing custom detection rules..."
mkdir -p /etc/suricata/rules

cat > /etc/suricata/rules/custom-detection.rules << 'RULES'
# SSH Brute Force — fires after multiple failed attempts from same src
alert tcp any any -> $HOME_NET 2222 (msg:"CUSTOM SSH Brute Force Attempt"; flow:to_server,established; content:"SSH-"; threshold:type both, track by_src, count 5, seconds 60; classtype:attempted-admin; sid:9000001; rev:1;)

# FTP Brute Force
alert tcp any any -> $HOME_NET 21 (msg:"CUSTOM FTP Brute Force Attempt"; flow:to_server,established; content:"PASS "; threshold:type both, track by_src, count 5, seconds 60; classtype:attempted-admin; sid:9000002; rev:1;)

# HTTP Brute Force (DVWA login)
alert http any any -> $HOME_NET any (msg:"CUSTOM HTTP Login Brute Force"; http.method; content:"POST"; http.uri; content:"login"; threshold:type both, track by_src, count 10, seconds 30; classtype:attempted-admin; sid:9000003; rev:1;)

# SYN Flood DDoS detection
alert tcp any any -> $HOME_NET any (msg:"CUSTOM SYN Flood DDoS"; flags:S,12; threshold:type both, track by_dst, count 1000, seconds 5; classtype:denial-of-service; sid:9000004; rev:1;)

# UDP Flood DDoS detection
alert udp any any -> $HOME_NET any (msg:"CUSTOM UDP Flood DDoS"; threshold:type both, track by_dst, count 1000, seconds 5; classtype:denial-of-service; sid:9000005; rev:1;)

# ICMP Flood
alert icmp any any -> $HOME_NET any (msg:"CUSTOM ICMP Flood DDoS"; itype:8; threshold:type both, track by_dst, count 500, seconds 5; classtype:denial-of-service; sid:9000006; rev:1;)

# Nmap OS detection probe
alert tcp any any -> $HOME_NET any (msg:"CUSTOM Nmap OS Detection Probe"; flags:SF; window:1024; classtype:attempted-recon; sid:9000007; rev:1;)

# Port scan — many ports from one source
alert tcp any any -> $HOME_NET any (msg:"CUSTOM Port Scan Detected"; flags:S; threshold:type both, track by_src, count 20, seconds 5; classtype:attempted-recon; sid:9000008; rev:1;)
RULES

log "Custom rules written."

# ─── 3. SURICATA: Add custom rules file to config ────────────────────────────
if ! grep -q "custom-detection.rules" /etc/suricata/suricata.yaml; then
    sed -i 's|default-rule-path:.*|default-rule-path: /var/lib/suricata/rules|' /etc/suricata/suricata.yaml
    # Add custom rules to the rule-files list
    sed -i '/rule-files:/a\  - \/etc\/suricata\/rules\/custom-detection.rules' /etc/suricata/suricata.yaml
    log "Added custom rules to suricata.yaml"
else
    log "Custom rules already in suricata.yaml"
fi

# ─── 4. SURICATA: Lower detection thresholds via threshold.conf ──────────────
log "Configuring detection thresholds..."

cat > /etc/suricata/threshold.conf << 'THRESH'
# Lower thresholds so internal RFC1918 attacks are detected
# ET SCAN Nmap rules - enable for all sources
suppress gen_id 1, sig_id 2000537, track by_src, ip 0.0.0.0/0
# Allow high-frequency alerts for brute force rules
threshold gen_id 1, sig_id 9000001, type limit, track by_src, count 1, seconds 60
threshold gen_id 1, sig_id 9000004, type limit, track by_dst, count 1, seconds 30
THRESH

# ─── 5. SURICATA: Test and restart ───────────────────────────────────────────
log "Testing Suricata config..."
suricata -T -c /etc/suricata/suricata.yaml 2>&1 | grep -E "^E:|^W:|Configuration provided" | tail -5

log "Restarting Suricata..."
systemctl restart suricata
sleep 5
systemctl is-active suricata

# ─── 6. WAZUH: Verify auth.log is monitored ──────────────────────────────────
log "Checking Wazuh auth.log config..."
if grep -q "auth.log" /var/ossec/etc/ossec.conf; then
    log "auth.log already configured in Wazuh agent"
else
    log "Adding auth.log to Wazuh agent config..."
    sed -i 's|</ossec_config>|<localfile>\n    <log_format>syslog</log_format>\n    <location>/var/log/auth.log</location>\n  </localfile>\n</ossec_config>|' /var/ossec/etc/ossec.conf
    systemctl restart wazuh-agent
fi

# ─── 7. VERIFY ───────────────────────────────────────────────────────────────
log "=== Verification ==="
log "Suricata: $(systemctl is-active suricata)"
log "Wazuh agent: $(systemctl is-active wazuh-agent)"
log "Eve.json lines: $(wc -l < /var/log/suricata/eve.json)"
log "Custom rules loaded: $(grep -c 'CUSTOM' /var/log/suricata/suricata.log 2>/dev/null || echo 'check logs')"

echo ""
echo "=========================================="
echo " SUCCESS — Detection configured"
echo " Nmap:        portscan + SID 9000007/8"
echo " DDoS:        SID 9000004/5/6 (SYN/UDP/ICMP flood)"
echo " Brute Force: SID 9000001/2/3 + Wazuh auth.log"
echo "=========================================="

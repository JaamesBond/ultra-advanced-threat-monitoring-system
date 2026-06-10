#!/usr/bin/env python3
# /var/ossec/integrations/custom-splunk-soar.py

import sys
import json
import requests
import os

# Read Wazuh arguments
alert_file = sys.argv[1]
api_key = sys.argv[2] if len(sys.argv) > 2 else ""
hook_url = "https://splunk-soar.bc-ctrl.internal:8443/rest/container"

# Read the alert file passed by Wazuh
with open(alert_file) as f:
    alert_json = json.load(f)

# Extract core fields
rule_id = alert_json.get("rule", {}).get("id")
level = alert_json.get("rule", {}).get("level")
description = alert_json.get("rule", {}).get("description")
mitre = alert_json.get("rule", {}).get("mitre", {}).get("id", [])
agent_name = alert_json.get("agent", {}).get("name", "Wazuh Server")

# Format the payload for Splunk SOAR
soar_payload = {
    "name": f"Wazuh Alert: {description}",
    "label": "wazuh_alert", # Ensure this label exists in Splunk SOAR
    "severity": "high" if int(level) >= 12 else "medium" if int(level) >= 8 else "low",
    "description": description,
    "source_data_identifier": f"wazuh-{alert_json.get('id')}",
    "artifacts": [
        {
            "name": "Wazuh Alert Details",
            "label": "event",
            "severity": "high" if int(level) >= 12 else "medium",
            "cef": {
                "rule_id": rule_id,
                "wazuh_level": level,
                "mitre_technique": ", ".join(mitre) if isinstance(mitre, list) else mitre,
                "raw_log": alert_json.get("full_log", ""),
            },
            "data": alert_json # Push the full JSON so SOAR playbooks can parse `aws.userIdentity`, `process_kprobe`, etc.
        }
    ]
}

headers = {
    "Content-Type": "application/json",
    "ph-auth-token": api_key  # Splunk SOAR API Token
}

# POST to Splunk SOAR (verify=False is used assuming internal self-signed certs)
try:
    response = requests.post(hook_url, headers=headers, json=soar_payload, verify=False, timeout=10)
    response.raise_for_status()
    sys.exit(0)
except Exception as e:
    with open("/var/ossec/logs/integrations.log", "a") as log:
        log.write(f"SOAR Integration Error: {str(e)}\n")
    sys.exit(1)
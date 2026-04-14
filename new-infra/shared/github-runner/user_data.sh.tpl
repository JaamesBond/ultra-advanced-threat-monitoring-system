#!/bin/bash
set -euo pipefail

RUNNER_VERSION="2.322.0"
RUNNER_USER="runner"
RUNNER_DIR="/opt/actions-runner"

# Install dependencies
dnf install -y jq libicu tar gzip

# Create runner user
useradd -m -s /bin/bash "$RUNNER_USER"

# Fetch GitHub PAT from Secrets Manager
PAT=$(aws secretsmanager get-secret-value \
  --secret-id "${secret_name}" \
  --region "${region}" \
  --query SecretString \
  --output text)

# Request a registration token from GitHub API
REG_TOKEN=$(curl -s \
  -X POST \
  -H "Authorization: token $PAT" \
  -H "Accept: application/vnd.github.v3+json" \
  "https://api.github.com/repos/${github_owner}/${github_repo}/actions/runners/registration-token" \
  | jq -r .token)

# Download and extract runner
mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"
curl -sL "https://github.com/actions/runner/releases/download/v$RUNNER_VERSION/actions-runner-linux-x64-$RUNNER_VERSION.tar.gz" \
  | tar xz

chown -R "$RUNNER_USER:$RUNNER_USER" "$RUNNER_DIR"

# Configure runner (non-interactive)
su - "$RUNNER_USER" -c "cd $RUNNER_DIR && ./config.sh \
  --url 'https://github.com/${github_owner}/${github_repo}' \
  --token '$REG_TOKEN' \
  --name '${runner_name}' \
  --labels '${runner_labels}' \
  --unattended \
  --replace"

# Install and start as systemd service
cd "$RUNNER_DIR"
./svc.sh install "$RUNNER_USER"
./svc.sh start

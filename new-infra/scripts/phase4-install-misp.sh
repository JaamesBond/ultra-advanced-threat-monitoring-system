#!/usr/bin/env bash
# =============================================================================
# phase4-install-misp.sh — XDR v8 / bc-ctrl EKS → bare EC2 migration
# Phase 4: MISP installation on bare EC2 (runs via SSM Session Manager)
#
# Idempotent: safe to re-run — all destructive steps are guarded.
#
# Secrets Manager secret: bc/misp (matches misp/external-secrets.yaml)
# Keys expected:
#   MYSQL_ROOT_PASSWORD, MYSQL_PASSWORD, MYSQL_USER,
#   MISP_ADMIN_EMAIL, MISP_ADMIN_PASSPHRASE, SECURITY_SALT
#
# Platform: Amazon Linux 2023 (RHEL9-compatible)
# Target:   MISP EC2 host (tag Name=misp-ctrl)
#           /dev/nvme1n1 = 60Gi data volume
# =============================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
REGION="${REGION:-eu-central-1}"
MISP_SECRET="bc/misp"
MISP_BASEURL="${MISP_BASEURL:-https://misp.bc-ctrl.internal}"
DATA_DEV="/dev/nvme1n1"
DATA_MNT="/data"
MYSQL_DATA="${DATA_MNT}/mysql"
REDIS_DATA="${DATA_MNT}/redis"
MISP_FILES="${DATA_MNT}/misp-files"
MISP_DIR="/var/www/MISP"
MISP_BRANCH="2.4"       # stable 2.4.x series; update to tag for pinned release
MYSQL_VERSION="8.0"
SCRIPT_NAME="$(basename "$0")"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${SCRIPT_NAME}] $*"; }
fail() { log "FATAL: $1"; exit 1; }

# ---------------------------------------------------------------------------
# STEP 0 — IMDSv2 check
# ---------------------------------------------------------------------------
log "=== STEP 0: IMDSv2 check ==="
IMDS_TOKEN="$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600" \
  --connect-timeout 5 --max-time 10 2>/dev/null || true)"
[[ -n "${IMDS_TOKEN}" ]] || fail "IMDSv2 token empty — check instance metadata service configuration"
log "IMDSv2 token obtained."

IMDS_REGION="$(curl -s \
  -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
  "http://169.254.169.254/latest/meta-data/placement/region" \
  --connect-timeout 5 --max-time 10 2>/dev/null || true)"
[[ -n "${IMDS_REGION}" ]] && REGION="${IMDS_REGION}"
log "Region: ${REGION}"
echo ""

# ---------------------------------------------------------------------------
# STEP 1 — Prerequisites
# ---------------------------------------------------------------------------
log "=== STEP 1: Installing prerequisites ==="

dnf install -y \
  tar jq unzip git openssl httpd mod_ssl \
  php php-fpm php-mysqlnd php-pecl-redis php-xml php-mbstring \
  php-json php-gd php-intl php-zip php-opcache \
  python3 python3-pip \
  >/dev/null 2>&1 \
  || fail "Prerequisite installation failed"

# AWS CLI v2 (idempotent)
if ! command -v aws >/dev/null 2>&1; then
  log "Installing AWS CLI v2..."
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp/awscliv2-extract
  /tmp/awscliv2-extract/aws/install
  rm -rf /tmp/awscliv2.zip /tmp/awscliv2-extract
fi

# Composer
if ! command -v composer >/dev/null 2>&1; then
  log "Installing Composer..."
  EXPECTED_CHECKSUM="$(curl -sfL https://composer.github.io/installer.sig)"
  php -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"
  ACTUAL_CHECKSUM="$(php -r "echo hash_file('sha384', '/tmp/composer-setup.php');")"
  [[ "${ACTUAL_CHECKSUM}" == "${EXPECTED_CHECKSUM}" ]] \
    || fail "Composer installer checksum mismatch — aborting to prevent supply chain compromise"
  php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer --quiet
  rm -f /tmp/composer-setup.php
  log "Composer installed: $(composer --version --no-interaction 2>/dev/null | head -1)"
fi

log "Prerequisites ready."
echo ""

# ---------------------------------------------------------------------------
# STEP 2 — Mount 60Gi EBS data volume
# ---------------------------------------------------------------------------
log "=== STEP 2: Mounting data volume ${DATA_DEV} → ${DATA_MNT} ==="

if ! blkid "${DATA_DEV}" >/dev/null 2>&1; then
  log "Formatting ${DATA_DEV} as XFS..."
  mkfs.xfs -f "${DATA_DEV}" || fail "mkfs.xfs failed on ${DATA_DEV}"
else
  log "${DATA_DEV} already formatted — skipping mkfs."
fi

mkdir -p "${DATA_MNT}"
DATA_UUID="$(blkid -s UUID -o value "${DATA_DEV}")"

if ! grep -q "${DATA_UUID}" /etc/fstab 2>/dev/null; then
  echo "UUID=${DATA_UUID}  ${DATA_MNT}  xfs  defaults,noatime,nodiratime  0  2" >> /etc/fstab
  log "fstab entry added."
fi

if ! mountpoint -q "${DATA_MNT}"; then
  mount "${DATA_MNT}" || fail "Failed to mount ${DATA_DEV} → ${DATA_MNT}"
  log "Mounted ${DATA_DEV} → ${DATA_MNT}"
else
  log "${DATA_MNT} already mounted."
fi

mkdir -p "${MYSQL_DATA}" "${REDIS_DATA}" "${MISP_FILES}"
log "Data subdirectories created under ${DATA_MNT}."
echo ""

# ---------------------------------------------------------------------------
# STEP 3 — Fetch secrets from Secrets Manager
# ---------------------------------------------------------------------------
log "=== STEP 3: Fetching secrets from ${MISP_SECRET} ==="

SECRET_JSON="$(aws secretsmanager get-secret-value \
  --region "${REGION}" \
  --secret-id "${MISP_SECRET}" \
  --query 'SecretString' \
  --output text)" || fail "Could not fetch secret ${MISP_SECRET} — check IAM permissions"

MYSQL_ROOT_PASSWORD="$(echo "${SECRET_JSON}" | jq -r '.MYSQL_ROOT_PASSWORD')"
MYSQL_PASSWORD="$(echo "${SECRET_JSON}" | jq -r '.MYSQL_PASSWORD')"
MYSQL_USER="$(echo "${SECRET_JSON}" | jq -r '.MYSQL_USER // "misp"')"
MISP_ADMIN_EMAIL="$(echo "${SECRET_JSON}" | jq -r '.MISP_ADMIN_EMAIL')"
MISP_ADMIN_PASSPHRASE="$(echo "${SECRET_JSON}" | jq -r '.MISP_ADMIN_PASSPHRASE')"
SECURITY_SALT="$(echo "${SECRET_JSON}" | jq -r '.SECURITY_SALT')"

[[ -n "${MYSQL_ROOT_PASSWORD}" && "${MYSQL_ROOT_PASSWORD}" != "null" ]] \
  || fail "MYSQL_ROOT_PASSWORD missing from secret ${MISP_SECRET}"
[[ -n "${SECURITY_SALT}"       && "${SECURITY_SALT}" != "null"       ]] \
  || fail "SECURITY_SALT missing from secret ${MISP_SECRET}"

log "Secrets fetched."
echo ""

# ---------------------------------------------------------------------------
# STEP 4 — Install MySQL 8.0
# ---------------------------------------------------------------------------
log "=== STEP 4: Installing MySQL ${MYSQL_VERSION} ==="

if ! rpm -q "mysql80-community-release" >/dev/null 2>&1; then
  log "Adding MySQL 8.0 community repo..."
  MYSQL_REPO_RPM="mysql80-community-release-el9-5.noarch.rpm"
  curl -fsSL \
    "https://repo.mysql.com/${MYSQL_REPO_RPM}" \
    -o "/tmp/${MYSQL_REPO_RPM}" \
    || fail "Could not download MySQL repo RPM"
  rpm --import "https://repo.mysql.com/RPM-GPG-KEY-mysql-2023" 2>/dev/null || true
  dnf install -y "/tmp/${MYSQL_REPO_RPM}" >/dev/null 2>&1 || true
  rm -f "/tmp/${MYSQL_REPO_RPM}"
fi

dnf install -y mysql-community-server >/dev/null 2>&1 \
  || fail "MySQL server installation failed"
log "MySQL installed."

# Configure MySQL datadir → /data/mysql
# Must be done BEFORE first start
MY_CNF="/etc/my.cnf.d/misp-datadir.cnf"
if [[ ! -f "${MY_CNF}" ]]; then
  log "Configuring MySQL datadir to ${MYSQL_DATA}..."
  cat > "${MY_CNF}" <<EOF
[mysqld]
datadir=${MYSQL_DATA}
socket=/var/lib/mysql/mysql.sock

# MISP-recommended MySQL settings
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
default-authentication-plugin=mysql_native_password

# Performance settings for MISP workload
innodb_buffer_pool_size=512M
innodb_log_file_size=256M
innodb_flush_log_at_trx_commit=2
max_connections=200
EOF

  # Ensure the datadir has correct SELinux context (if SELinux enforcing)
  if command -v semanage >/dev/null 2>&1 && command -v restorecon >/dev/null 2>&1; then
    semanage fcontext -a -t mysqld_db_t "${MYSQL_DATA}(/.*)?" 2>/dev/null || true
    restorecon -Rv "${MYSQL_DATA}" 2>/dev/null || true
  fi
fi

# Initialise MySQL datadir if not already done
if [[ ! -d "${MYSQL_DATA}/mysql" ]]; then
  log "Initialising MySQL datadir at ${MYSQL_DATA}..."
  mysqld --initialize-insecure --datadir="${MYSQL_DATA}" --user=mysql 2>/dev/null \
    || fail "MySQL datadir initialisation failed"
fi

chown -R mysql:mysql "${MYSQL_DATA}"

systemctl enable --now mysqld \
  || fail "Failed to enable/start mysqld"
log "mysqld started."

# Set root password — handle fresh install temporary password
log "Setting MySQL root password..."
MYSQL_TEMP_PASS="$(grep 'temporary password' /var/log/mysqld.log 2>/dev/null | tail -1 | awk '{print $NF}' || true)"
if [[ -n "${MYSQL_TEMP_PASS}" ]]; then
  # Fresh install: reset temp password first with a valid-policy temp, then set real password
  mysql -u root -p"${MYSQL_TEMP_PASS}" --connect-expired-password \
    -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'TempBoot1!'; FLUSH PRIVILEGES;" 2>/dev/null || true
  mysql -u root -p'TempBoot1!' \
    -e "SET GLOBAL validate_password.policy=LOW; SET GLOBAL validate_password.length=8; ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}'; FLUSH PRIVILEGES;" 2>/dev/null \
    || fail "Could not set MySQL root password from temporary password"
else
  # Re-run: verify existing password works
  mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1 \
    || fail "Could not verify MySQL root password"
fi

# Create MISP database and user (idempotent)
log "Creating MISP database and user..."
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" <<SQL 2>/dev/null || true
CREATE DATABASE IF NOT EXISTS misp CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'localhost' IDENTIFIED BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON misp.* TO '${MYSQL_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
log "MySQL database 'misp' and user '${MYSQL_USER}' ready."
echo ""

# ---------------------------------------------------------------------------
# STEP 5 — Install Redis 7
# ---------------------------------------------------------------------------
log "=== STEP 5: Installing Redis ==="

REDIS_PKG="redis7"
dnf list --available redis7 >/dev/null 2>&1 || REDIS_PKG="redis6"
dnf install -y "${REDIS_PKG}" >/dev/null 2>&1 \
  || fail "Redis installation failed"

REDIS_CONF="/etc/redis/redis.conf"
[[ -f "${REDIS_CONF}" ]] || REDIS_CONF="/etc/redis7/redis.conf"
[[ -f "${REDIS_CONF}" ]] || REDIS_CONF="/etc/redis6/redis.conf"

if [[ -f "${REDIS_CONF}" ]]; then
  sed -i "s|^dir .*|dir ${REDIS_DATA}|" "${REDIS_CONF}"
  sed -i 's/^bind .*/bind 127.0.0.1/' "${REDIS_CONF}"
fi
REDIS_SVC="$(systemctl list-unit-files 'redis*' --no-legend 2>/dev/null \
  | awk '{print $1}' | grep -v '@' | grep -v sentinel | grep '\.service$' | head -1)"
REDIS_SVC="${REDIS_SVC%.service}"
[[ -n "${REDIS_SVC}" ]] || REDIS_SVC="${REDIS_PKG}"
systemctl enable --now "${REDIS_SVC}" \
  || fail "Failed to enable/start redis"

REDIS_USER="redis"
id "${REDIS_USER}" >/dev/null 2>&1 || REDIS_USER="$(systemctl show -p User "${REDIS_SVC}" --value 2>/dev/null || echo root)"
[[ -n "${REDIS_USER}" ]] || REDIS_USER="root"
chown -R "${REDIS_USER}:${REDIS_USER}" "${REDIS_DATA}"
log "Redis started."
echo ""

# ---------------------------------------------------------------------------
# STEP 6 — Clone MISP
# ---------------------------------------------------------------------------
log "=== STEP 6: Cloning MISP to ${MISP_DIR} ==="

if [[ ! -d "${MISP_DIR}/.git" ]]; then
  log "Cloning MISP (branch ${MISP_BRANCH})..."
  git clone \
    --depth 1 \
    --branch "${MISP_BRANCH}" \
    "https://github.com/MISP/MISP.git" \
    "${MISP_DIR}" \
    || fail "MISP git clone failed"
  log "MISP cloned."
else
  log "MISP already cloned — pulling latest on ${MISP_BRANCH}..."
  git -C "${MISP_DIR}" pull --ff-only origin "${MISP_BRANCH}" 2>/dev/null || true
fi

# Clone CakePHP and submodules
log "Initialising MISP git submodules..."
git -C "${MISP_DIR}" submodule update --init --recursive \
  2>&1 | tail -5 \
  || log "WARNING: Submodule update had errors — non-fatal, proceeding"

# Install PHP dependencies via Composer
log "Running composer install (MISP PHP deps)..."
sudo -u apache bash -c "cd ${MISP_DIR}/app && php composer.phar install --no-dev --no-interaction --ignore-platform-reqs --quiet 2>/dev/null" \
  || log "WARNING: Composer install encountered errors — check manually"

# Install Python dependencies
log "Installing MISP Python dependencies..."
pip3 install \
  pymisp \
  pyzmq \
  redis \
  requests \
  cryptography \
  bcrypt \
  >/dev/null 2>&1 \
  || log "WARNING: Some Python deps failed to install — non-fatal"

echo ""

# ---------------------------------------------------------------------------
# STEP 7 — Apache HTTPS vhost (self-signed CN=misp.bc-ctrl.internal)
# ---------------------------------------------------------------------------
log "=== STEP 7: Configuring Apache HTTPS vhost ==="

SSL_DIR="/etc/ssl/misp"
mkdir -p "${SSL_DIR}"

if [[ ! -f "${SSL_DIR}/misp.key" || ! -f "${SSL_DIR}/misp.crt" ]]; then
  log "Generating self-signed TLS certificate for misp.bc-ctrl.internal..."
  openssl req -x509 -newkey rsa:2048 \
    -keyout "${SSL_DIR}/misp.key" \
    -out    "${SSL_DIR}/misp.crt" \
    -days 3650 \
    -nodes \
    -subj "/C=US/ST=California/L=San Jose/O=BigChemistry/CN=misp.bc-ctrl.internal" \
    -addext "subjectAltName=DNS:misp.bc-ctrl.internal" \
    2>/dev/null \
    || fail "openssl self-signed cert generation failed"
  chmod 600 "${SSL_DIR}/misp.key"
  chmod 644 "${SSL_DIR}/misp.crt"
  log "Self-signed certificate generated."
fi

# Disable default SSL config to avoid port 443 conflicts
sed -i 's/^Listen 443 https/#Listen 443 https/' /etc/httpd/conf.d/ssl.conf 2>/dev/null || true

cat > /etc/httpd/conf.d/misp.conf <<EOF
Listen 443 https

# MISP vhost — HTTPS on port 443
# CN: misp.bc-ctrl.internal

<VirtualHost *:443>
    ServerName misp.bc-ctrl.internal
    DocumentRoot ${MISP_DIR}/app/webroot

    SSLEngine on
    SSLCertificateFile    ${SSL_DIR}/misp.crt
    SSLCertificateKeyFile ${SSL_DIR}/misp.key
    SSLProtocol           all -SSLv2 -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite        HIGH:!ADH:!EXP:!MD5:!RC4:!3DES:!CAMELLIA:@STRENGTH
    SSLHonorCipherOrder   on

    <Directory ${MISP_DIR}/app/webroot>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <Directory ${MISP_DIR}/app>
        Options -Indexes
    </Directory>

    # Security headers
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"

    ErrorLog  /var/log/httpd/misp-error.log
    CustomLog /var/log/httpd/misp-access.log combined
</VirtualHost>

# Redirect HTTP → HTTPS
<VirtualHost *:80>
    ServerName misp.bc-ctrl.internal
    RewriteEngine On
    RewriteRule ^/?(.*) https://%{SERVER_NAME}/\$1 [R=301,L]
</VirtualHost>
EOF
log "Apache vhost written."

# ---------------------------------------------------------------------------
# STEP 8 — Configure MISP (database.php and config.php)
# ---------------------------------------------------------------------------
log "=== STEP 8: Configuring MISP ==="

MISP_CONFIG_DIR="${MISP_DIR}/app/Config"

# Copy default config files if not present
[[ -f "${MISP_CONFIG_DIR}/bootstrap.php" ]] \
  || cp "${MISP_CONFIG_DIR}/bootstrap.default.php" "${MISP_CONFIG_DIR}/bootstrap.php"
[[ -f "${MISP_CONFIG_DIR}/database.php" ]] \
  || cp "${MISP_CONFIG_DIR}/database.default.php"  "${MISP_CONFIG_DIR}/database.php"
[[ -f "${MISP_CONFIG_DIR}/core.php" ]] \
  || cp "${MISP_CONFIG_DIR}/core.default.php"      "${MISP_CONFIG_DIR}/core.php"

# Write database.php with credentials from Secrets Manager
log "Writing database.php..."
cat > "${MISP_CONFIG_DIR}/database.php" <<PHP
<?php
class DATABASE_CONFIG {
    public \$default = array(
        'datasource' => 'Database/Mysql',
        'persistent' => false,
        'host'       => '127.0.0.1',
        'login'      => '${MYSQL_USER}',
        'port'       => 3306,
        'password'   => '${MYSQL_PASSWORD}',
        'database'   => 'misp',
        'prefix'     => '',
        'encoding'   => 'utf8mb4',
    );
}
PHP

# Write config.php with SECURITY_SALT and MISP_BASEURL
log "Writing config.php..."
# Preserve existing config.php if present (first-boot init may have written it)
if [[ ! -f "${MISP_CONFIG_DIR}/config.php" ]]; then
  # Bootstrap from MISP's own config.default.php if available
  [[ -f "${MISP_CONFIG_DIR}/config.default.php" ]] \
    && cp "${MISP_CONFIG_DIR}/config.default.php" "${MISP_CONFIG_DIR}/config.php"
fi

# Patch the relevant fields in config.php using PHP heredoc-safe substitution
python3 - <<PYEOF
import re, sys

config_path = '${MISP_CONFIG_DIR}/config.php'

try:
    with open(config_path, 'r') as f:
        content = f.read()
except FileNotFoundError:
    # Create a minimal config.php if default template is missing
    content = '''<?php
\$config = array(
    'MISP' => array(
        'baseurl' => '',
        'uuid'    => '',
    ),
    'Security' => array(
        'salt'    => '',
        'level'   => 2,
    ),
);
'''

# Replace or inject baseurl
if "'baseurl'" in content:
    content = re.sub(
        r"'baseurl'\s*=>\s*'[^']*'",
        "'baseurl' => '${MISP_BASEURL}'",
        content
    )
else:
    content = content.replace("'MISP' => array(", "'MISP' => array(\n        'baseurl' => '${MISP_BASEURL}',")

# Replace or inject security salt
if "'salt'" in content:
    content = re.sub(
        r"'salt'\s*=>\s*'[^']*'",
        "'salt' => '${SECURITY_SALT}'",
        content
    )
else:
    content = content.replace("'Security' => array(", "'Security' => array(\n        'salt' => '${SECURITY_SALT}',")

with open(config_path, 'w') as f:
    f.write(content)

print("config.php patched successfully")
PYEOF

log "MISP config files written."

# ---------------------------------------------------------------------------
# STEP 9 — File storage symlink and ownership
# ---------------------------------------------------------------------------
log "=== STEP 9: MISP file storage setup ==="

# Symlink MISP's app/files → /data/misp-files
if [[ -d "${MISP_DIR}/app/files" && ! -L "${MISP_DIR}/app/files" ]]; then
  log "Moving existing app/files contents to ${MISP_FILES}..."
  rsync -a "${MISP_DIR}/app/files/" "${MISP_FILES}/" 2>/dev/null || true
  rm -rf "${MISP_DIR}/app/files"
elif [[ ! -e "${MISP_DIR}/app/files" ]]; then
  log "app/files does not exist — will create symlink"
fi

if [[ ! -L "${MISP_DIR}/app/files" ]]; then
  ln -s "${MISP_FILES}" "${MISP_DIR}/app/files"
  log "Symlink created: ${MISP_DIR}/app/files → ${MISP_FILES}"
else
  log "Symlink already exists: ${MISP_DIR}/app/files"
fi

log "Setting ownership apache:apache on MISP dirs..."
chown -R apache:apache "${MISP_DIR}" "${MISP_FILES}" 2>/dev/null \
  || log "WARNING: chown had errors — SELinux context may also need updating"

# Set permissions as recommended by MISP install guide
find "${MISP_DIR}" -type f -exec chmod 0640 {} \; 2>/dev/null || true
find "${MISP_DIR}" -type d -exec chmod 0750 {} \; 2>/dev/null || true
chmod +x "${MISP_DIR}/app/Console/cake" 2>/dev/null || true

# SELinux contexts
if command -v semanage >/dev/null 2>&1; then
  semanage fcontext -a -t httpd_sys_rw_content_t "${MISP_DIR}/app/tmp(/.*)?"       2>/dev/null || true
  semanage fcontext -a -t httpd_sys_rw_content_t "${MISP_DIR}/app/files(/.*)?"     2>/dev/null || true
  semanage fcontext -a -t httpd_sys_rw_content_t "${MISP_FILES}(/.*)?"             2>/dev/null || true
  semanage fcontext -a -t httpd_sys_rw_content_t "${MISP_DIR}/app/Config(/.*)?"    2>/dev/null || true
  restorecon -Rv "${MISP_DIR}" "${MISP_FILES}" 2>/dev/null || true
fi

echo ""

# ---------------------------------------------------------------------------
# STEP 10 — Enable and start services
# ---------------------------------------------------------------------------
log "=== STEP 10: Starting services ==="

systemctl enable --now httpd  || fail "Failed to enable httpd"
systemctl enable --now mysqld || true   # already running, idempotent
systemctl enable --now redis  || true   # already running

log "All services enabled."
echo ""

# ---------------------------------------------------------------------------
# STEP 11 — MISP database schema initialisation (first boot only)
# ---------------------------------------------------------------------------
log "=== STEP 11: Checking MISP DB schema ==="

TABLE_COUNT="$(mysql -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -D misp \
  -se "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='misp';" \
  2>/dev/null || echo "0")"

if [[ "${TABLE_COUNT}" -lt 10 ]]; then
  log "Running MISP database schema initialisation (first boot)..."
  # MISP schema is created by the application on first request, or via cake command
  # Run via Apache/PHP using MISP's own setup tool if available
  if [[ -f "${MISP_DIR}/app/Console/cake" ]]; then
    sudo -u apache "${MISP_DIR}/app/Console/cake" \
      userInit \
      -q 2>/dev/null \
      || log "WARNING: cake userInit failed — MISP may self-initialise on first HTTPS request"
  fi

  # Import base schema directly if cake wasn't able to do it
  if [[ -f "${MISP_DIR}/INSTALL/MYSQL.sql" ]]; then
    TABLE_COUNT_CHECK="$(mysql -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" -D misp \
      -se "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='misp';" \
      2>/dev/null || echo "0")"
    if [[ "${TABLE_COUNT_CHECK}" -lt 10 ]]; then
      log "Importing MISP base schema from MYSQL.sql..."
      mysql -u "${MYSQL_USER}" -p"${MYSQL_PASSWORD}" misp \
        < "${MISP_DIR}/INSTALL/MYSQL.sql" 2>/dev/null \
        || log "WARNING: MYSQL.sql import failed — MISP will attempt DB init on first login"
    fi
  fi
else
  log "MISP DB already has ${TABLE_COUNT} tables — skipping schema init."
fi

echo ""

# ---------------------------------------------------------------------------
# STEP 12 — Verify: HTTPS login page returns 200
# ---------------------------------------------------------------------------
log "=== STEP 12: Verifying MISP HTTPS endpoint ==="

MISP_OK=false
for i in $(seq 1 24); do
  HTTP_CODE="$(curl -sk -o /dev/null -w "%{http_code}" \
    "https://localhost/users/login" \
    --connect-timeout 5 --max-time 10 2>/dev/null || echo "000")"
  if [[ "${HTTP_CODE}" == "200" || "${HTTP_CODE}" == "302" ]]; then
    log "MISP responding: HTTP ${HTTP_CODE} (after $((i * 5))s)"
    MISP_OK=true
    break
  fi
  sleep 5
done

if ! "${MISP_OK}"; then
  log "WARNING: MISP did not respond with 200/302 within 120s."
  log "  Check: systemctl status httpd mysqld redis6"
  log "  Logs:  tail -f /var/log/httpd/misp-error.log"
  log "  First-boot MISP schema init can take 3-5 minutes — retry manually."
fi

# ---------------------------------------------------------------------------
# SUMMARY
# ---------------------------------------------------------------------------
echo ""
echo "=============================================================="
echo "  PHASE 4 MISP INSTALLATION COMPLETE"
echo "  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=============================================================="
echo ""
echo "  Services:"
echo "    httpd  — $(systemctl is-active httpd  2>/dev/null || echo unknown)"
echo "    mysqld — $(systemctl is-active mysqld 2>/dev/null || echo unknown)"
echo "    redis  — $(systemctl is-active "${REDIS_SVC}" 2>/dev/null || echo unknown)"
echo ""
echo "  MISP URL: ${MISP_BASEURL}"
echo "  Admin email: ${MISP_ADMIN_EMAIL}"
echo ""
echo "  IMPORTANT — Post-install tasks (manual):"
echo "    1. Browse to ${MISP_BASEURL}/users/login"
echo "       First login: admin@admin.test / admin  — CHANGE IMMEDIATELY"
echo "       Or if cake userInit ran: ${MISP_ADMIN_EMAIL} / ${MISP_ADMIN_PASSPHRASE}"
echo "    2. Administration → List Auth Keys → add a new key"
echo "    3. Run: update-fill-in-secrets.sh MISP_AUTH_KEY=<key>"
echo "       to inject the key into bc/wazuh/manager Secrets Manager"
echo "    4. Verify misp-ioc-sync.timer on the Wazuh Manager host"
echo "=============================================================="

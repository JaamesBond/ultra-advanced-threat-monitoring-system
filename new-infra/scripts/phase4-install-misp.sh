#!/usr/bin/env bash
# =============================================================================
# phase4-install-misp.sh — XDR v8 / bc-ctrl EC2
# Phase 4: MISP fully-automated installation on Amazon Linux 2023
#
# Idempotent: safe to re-run — all destructive steps are guarded.
#
# WHY PHP 7.4 FROM SOURCE:
#   AL2023 ships PHP 8.x. MISP 2.4.x uses CakePHP 2.x which loads
#   Model/Attribute.php into the global namespace. PHP 8.0+ introduced
#   a built-in `Attribute` class — this causes a fatal "Cannot declare
#   class Attribute, because the name is already in use" on every request.
#   PHP 7.4 has no such conflict. Remi/SCL repos don't support AL2023,
#   so we compile PHP 7.4.33 (last 7.4 release) from source.
#
# Secrets Manager secret: bc/misp
# Keys expected:
#   MYSQL_ROOT_PASSWORD, MYSQL_PASSWORD, MYSQL_USER,
#   MISP_ADMIN_EMAIL, MISP_ADMIN_PASSPHRASE, SECURITY_SALT
#
# Platform: Amazon Linux 2023
# Target:   bc-ctrl EC2 (tag Name=misp-ctrl)
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
MISP_BRANCH="2.4"
MYSQL_VERSION="8.0"

PHP74_VERSION="7.4.33"
PHP74_PREFIX="/usr/local/php74"
PHP74_BIN="${PHP74_PREFIX}/bin/php"
PHP74_FPM_BIN="${PHP74_PREFIX}/sbin/php-fpm"
PHP74_CONF="/etc/php74"
PHP74_SOCK="/run/php74-fpm/www.sock"

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
[[ -n "${IMDS_TOKEN}" ]] || fail "IMDSv2 token empty"
log "IMDSv2 token obtained."

IMDS_REGION="$(curl -s \
  -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
  "http://169.254.169.254/latest/meta-data/placement/region" \
  --connect-timeout 5 --max-time 10 2>/dev/null || true)"
[[ -n "${IMDS_REGION}" ]] && REGION="${IMDS_REGION}"
log "Region: ${REGION}"
echo ""

# ---------------------------------------------------------------------------
# STEP 1 — Build dependencies + base packages (no PHP from dnf)
# ---------------------------------------------------------------------------
log "=== STEP 1: Installing build dependencies and base packages ==="

dnf install -y \
  tar jq unzip git openssl httpd mod_ssl \
  python3 python3-pip \
  gcc gcc-c++ make autoconf \
  libxml2-devel libcurl-devel openssl-devel sqlite-devel \
  bzip2-devel libzip-devel oniguruma-devel \
  re2c libsodium-devel gd-devel libpng-devel libjpeg-devel \
  >/dev/null 2>&1 \
  || fail "Build dependency installation failed"

# AWS CLI v2 (idempotent)
if ! command -v aws >/dev/null 2>&1; then
  log "Installing AWS CLI v2..."
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp/awscliv2-extract
  /tmp/awscliv2-extract/aws/install
  rm -rf /tmp/awscliv2.zip /tmp/awscliv2-extract
fi

log "Base packages ready."
echo ""

# ---------------------------------------------------------------------------
# STEP 2 — Build PHP 7.4.33 from source
#
# AL2023 only ships PHP 8.x. PHP 8.0+ has a built-in `Attribute` class
# that fatally conflicts with MISP's Model/Attribute.php in CakePHP 2.x.
# We also patch ext/openssl/openssl.c to add the RSA_SSLV23_PADDING
# constant removed in OpenSSL 3.x (shipped with AL2023).
# ---------------------------------------------------------------------------
log "=== STEP 2: Building PHP ${PHP74_VERSION} from source (~15 min) ==="

if [[ -x "${PHP74_BIN}" ]]; then
  log "PHP 7.4 already built at ${PHP74_BIN} — skipping compile."
else
  PHP74_SRC="/usr/local/src/php-${PHP74_VERSION}"

  if [[ ! -d "${PHP74_SRC}" ]]; then
    log "Downloading PHP ${PHP74_VERSION} source..."
    curl -fsSL "https://www.php.net/distributions/php-${PHP74_VERSION}.tar.gz" \
      -o "/tmp/php-${PHP74_VERSION}.tar.gz" \
      || fail "PHP source download failed"
    tar xzf "/tmp/php-${PHP74_VERSION}.tar.gz" -C /usr/local/src/
    rm -f "/tmp/php-${PHP74_VERSION}.tar.gz"
  fi

  cd "${PHP74_SRC}"

  # Patch: RSA_SSLV23_PADDING was removed in OpenSSL 3.x (AL2023 ships 3.x)
  if ! grep -q "RSA_SSLV23_PADDING 2" ext/openssl/openssl.c; then
    log "Applying OpenSSL 3.x compat patch (RSA_SSLV23_PADDING)..."
    sed -i '/#include "php_openssl.h"/a #ifndef RSA_SSLV23_PADDING\n#define RSA_SSLV23_PADDING 2\n#endif' \
      ext/openssl/openssl.c
  fi

  log "Configuring PHP ${PHP74_VERSION}..."
  ./configure \
    --prefix="${PHP74_PREFIX}" \
    --with-config-file-path="${PHP74_CONF}" \
    --with-config-file-scan-dir="${PHP74_CONF}/php.d" \
    --enable-fpm \
    --with-fpm-user=apache \
    --with-fpm-group=apache \
    --enable-mbstring \
    --with-openssl \
    --with-curl \
    --enable-mysqlnd \
    --with-mysqli=mysqlnd \
    --with-pdo-mysql=mysqlnd \
    --enable-json \
    --with-zlib \
    --enable-xml \
    --enable-dom \
    --enable-simplexml \
    --enable-gd \
    --enable-bcmath \
    --enable-sockets \
    --with-sodium \
    >/dev/null 2>&1 \
    || fail "PHP configure failed"

  log "Compiling PHP ${PHP74_VERSION} (this takes ~15 minutes)..."
  make -j"$(nproc)" >/dev/null 2>&1 \
    || fail "PHP build failed"

  make install >/dev/null 2>&1 \
    || fail "PHP install failed"

  log "PHP ${PHP74_VERSION} installed at ${PHP74_PREFIX}."
fi

# ---------------------------------------------------------------------------
# STEP 3 — Configure PHP 7.4 FPM
# ---------------------------------------------------------------------------
log "=== STEP 3: Configuring PHP 7.4 FPM ==="

mkdir -p "${PHP74_CONF}/php.d"

# php.ini
if [[ ! -f "${PHP74_CONF}/php.ini" ]]; then
  cp "/usr/local/src/php-${PHP74_VERSION}/php.ini-production" "${PHP74_CONF}/php.ini"
fi

# php-fpm.conf
mkdir -p "${PHP74_CONF}/fpm.d"
if [[ ! -f "${PHP74_CONF}/php-fpm.conf" ]]; then
  cp "${PHP74_PREFIX}/etc/php-fpm.conf.default" "${PHP74_CONF}/php-fpm.conf"
  sed -i "s|^include=.*|include=${PHP74_CONF}/fpm.d/*.conf|" "${PHP74_CONF}/php-fpm.conf"
fi

# www pool
if [[ ! -f "${PHP74_CONF}/fpm.d/www.conf" ]]; then
  cp "${PHP74_PREFIX}/etc/php-fpm.d/www.conf.default" "${PHP74_CONF}/fpm.d/www.conf"
fi

sed -i "s|^listen = .*|listen = ${PHP74_SOCK}|"        "${PHP74_CONF}/fpm.d/www.conf"
sed -i 's|;listen.owner = .*|listen.owner = apache|'   "${PHP74_CONF}/fpm.d/www.conf"
sed -i 's|;listen.group = .*|listen.group = apache|'   "${PHP74_CONF}/fpm.d/www.conf"
sed -i 's|;listen.mode = .*|listen.mode = 0660|'       "${PHP74_CONF}/fpm.d/www.conf"

# systemd unit
cat > /etc/systemd/system/php74-fpm.service <<'UNIT'
[Unit]
Description=PHP 7.4 FastCGI Process Manager
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/php74/sbin/php-fpm --nodaemonize --fpm-config /etc/php74/php-fpm.conf
RuntimeDirectory=php74-fpm
RuntimeDirectoryMode=0755
ExecReload=/bin/kill -USR2 $MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now php74-fpm \
  || fail "Failed to start php74-fpm"
log "PHP 7.4 FPM running, socket: ${PHP74_SOCK}"
echo ""

# ---------------------------------------------------------------------------
# STEP 4 — Mount 60Gi EBS data volume
# ---------------------------------------------------------------------------
log "=== STEP 4: Mounting data volume ${DATA_DEV} → ${DATA_MNT} ==="

if ! blkid "${DATA_DEV}" >/dev/null 2>&1; then
  log "Formatting ${DATA_DEV} as XFS..."
  mkfs.xfs -f "${DATA_DEV}" || fail "mkfs.xfs failed"
else
  log "${DATA_DEV} already formatted — skipping mkfs."
fi

mkdir -p "${DATA_MNT}"
DATA_UUID="$(blkid -s UUID -o value "${DATA_DEV}")"

if ! grep -q "${DATA_UUID}" /etc/fstab 2>/dev/null; then
  echo "UUID=${DATA_UUID}  ${DATA_MNT}  xfs  defaults,noatime  0  2" >> /etc/fstab
fi

if ! mountpoint -q "${DATA_MNT}"; then
  mount "${DATA_MNT}" || fail "Failed to mount ${DATA_DEV}"
fi

mkdir -p "${MYSQL_DATA}" "${REDIS_DATA}" "${MISP_FILES}"
log "Data volume ready."
echo ""

# ---------------------------------------------------------------------------
# STEP 5 — Fetch secrets from Secrets Manager
# ---------------------------------------------------------------------------
log "=== STEP 5: Fetching secrets from ${MISP_SECRET} ==="

SECRET_JSON="$(aws secretsmanager get-secret-value \
  --region "${REGION}" \
  --secret-id "${MISP_SECRET}" \
  --query 'SecretString' \
  --output text)" || fail "Could not fetch secret ${MISP_SECRET}"

MYSQL_ROOT_PASSWORD="$(echo "${SECRET_JSON}" | jq -r '.MYSQL_ROOT_PASSWORD')"
MYSQL_PASSWORD="$(echo "${SECRET_JSON}" | jq -r '.MYSQL_PASSWORD')"
MYSQL_USER="$(echo "${SECRET_JSON}" | jq -r '.MYSQL_USER // "misp"')"
MISP_ADMIN_EMAIL="$(echo "${SECRET_JSON}" | jq -r '.MISP_ADMIN_EMAIL')"
MISP_ADMIN_PASSPHRASE="$(echo "${SECRET_JSON}" | jq -r '.MISP_ADMIN_PASSPHRASE')"
SECURITY_SALT="$(echo "${SECRET_JSON}" | jq -r '.SECURITY_SALT')"

[[ -n "${MYSQL_ROOT_PASSWORD}" && "${MYSQL_ROOT_PASSWORD}" != "null" ]] \
  || fail "MYSQL_ROOT_PASSWORD missing from secret"
[[ -n "${SECURITY_SALT}"       && "${SECURITY_SALT}"       != "null" ]] \
  || fail "SECURITY_SALT missing from secret"

log "Secrets fetched."
echo ""

# ---------------------------------------------------------------------------
# STEP 6 — Install MySQL 8.0
# ---------------------------------------------------------------------------
log "=== STEP 6: Installing MySQL ${MYSQL_VERSION} ==="

if ! rpm -q "mysql80-community-release" >/dev/null 2>&1; then
  MYSQL_REPO_RPM="mysql80-community-release-el9-5.noarch.rpm"
  curl -fsSL "https://repo.mysql.com/${MYSQL_REPO_RPM}" -o "/tmp/${MYSQL_REPO_RPM}" \
    || fail "MySQL repo download failed"
  rpm --import "https://repo.mysql.com/RPM-GPG-KEY-mysql-2023" 2>/dev/null || true
  dnf install -y "/tmp/${MYSQL_REPO_RPM}" >/dev/null 2>&1 || true
  rm -f "/tmp/${MYSQL_REPO_RPM}"
fi

dnf install -y mysql-community-server >/dev/null 2>&1 \
  || fail "MySQL install failed"

MY_CNF="/etc/my.cnf.d/misp-datadir.cnf"
if [[ ! -f "${MY_CNF}" ]]; then
  cat > "${MY_CNF}" <<EOF
[mysqld]
datadir=${MYSQL_DATA}
socket=/var/lib/mysql/mysql.sock
character-set-server=utf8mb4
collation-server=utf8mb4_unicode_ci
default-authentication-plugin=mysql_native_password
innodb_buffer_pool_size=512M
innodb_log_file_size=256M
innodb_flush_log_at_trx_commit=2
max_connections=200
EOF
  if command -v semanage >/dev/null 2>&1; then
    semanage fcontext -a -t mysqld_db_t "${MYSQL_DATA}(/.*)?" 2>/dev/null || true
    restorecon -Rv "${MYSQL_DATA}" 2>/dev/null || true
  fi
fi

if [[ ! -d "${MYSQL_DATA}/mysql" ]]; then
  mysqld --initialize-insecure --datadir="${MYSQL_DATA}" --user=mysql 2>/dev/null \
    || fail "MySQL datadir init failed"
fi

chown -R mysql:mysql "${MYSQL_DATA}"
systemctl enable --now mysqld || fail "Failed to start mysqld"

# Set root password — handle fresh install temporary password
log "Setting MySQL root password..."
MYSQL_TEMP_PASS="$(grep 'temporary password' /var/log/mysqld.log 2>/dev/null \
  | tail -1 | awk '{print $NF}' || true)"

if [[ -n "${MYSQL_TEMP_PASS}" ]]; then
  # Reset temp password first (policy requires a "valid" intermediate password)
  mysql -u root -p"${MYSQL_TEMP_PASS}" --connect-expired-password \
    -e "ALTER USER 'root'@'localhost' IDENTIFIED BY 'TempBoot1!'; FLUSH PRIVILEGES;" \
    2>/dev/null || true
  mysql -u root -p'TempBoot1!' \
    -e "SET GLOBAL validate_password.policy=LOW;
        SET GLOBAL validate_password.length=8;
        ALTER USER 'root'@'localhost' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}';
        FLUSH PRIVILEGES;" \
    2>/dev/null \
    || fail "Could not set MySQL root password from temporary password"
  log "MySQL root password set from temporary password."
else
  mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1 \
    || fail "MySQL root password verification failed"
  log "MySQL root password already set."
fi

# Create MISP database and user (idempotent)
mysql -u root -p"${MYSQL_ROOT_PASSWORD}" 2>/dev/null <<SQL || true
CREATE DATABASE IF NOT EXISTS misp CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${MYSQL_USER}'@'127.0.0.1' IDENTIFIED WITH mysql_native_password BY '${MYSQL_PASSWORD}';
GRANT ALL PRIVILEGES ON misp.* TO '${MYSQL_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
log "MySQL database and user ready."
echo ""

# ---------------------------------------------------------------------------
# STEP 7 — Install Redis
# ---------------------------------------------------------------------------
log "=== STEP 7: Installing Redis ==="

REDIS_PKG="redis7"
dnf list --available redis7 >/dev/null 2>&1 || REDIS_PKG="redis6"
dnf install -y "${REDIS_PKG}" >/dev/null 2>&1 || fail "Redis install failed"

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
systemctl enable --now "${REDIS_SVC}" || fail "Failed to start redis"
log "Redis started."
echo ""

# ---------------------------------------------------------------------------
# STEP 8 — Clone MISP and install Composer + PHP deps
# ---------------------------------------------------------------------------
log "=== STEP 8: Cloning MISP and installing PHP dependencies ==="

if [[ ! -d "${MISP_DIR}/.git" ]]; then
  git clone --depth 1 --branch "${MISP_BRANCH}" \
    "https://github.com/MISP/MISP.git" "${MISP_DIR}" \
    || fail "MISP git clone failed"
else
  log "MISP already cloned — pulling latest..."
  git -C "${MISP_DIR}" pull --ff-only origin "${MISP_BRANCH}" 2>/dev/null || true
fi

log "Initialising MISP git submodules..."
git -C "${MISP_DIR}" submodule update --init --recursive 2>&1 | tail -3 || true

# Install Composer using PHP 7.4
if [[ ! -f /usr/local/bin/composer ]]; then
  log "Installing Composer..."
  HOME=/root "${PHP74_BIN}" -r "copy('https://getcomposer.org/installer', '/tmp/composer-setup.php');"
  HOME=/root "${PHP74_BIN}" /tmp/composer-setup.php \
    --install-dir=/usr/local/bin --filename=composer --quiet
  rm -f /tmp/composer-setup.php
fi

# Patch composer.json to be PHP 7.4 compatible:
#   - Relax PHP version constraint (original: >=7.4.0,<8.0.0)
#   - Keep browscap-php at 5.1.0 (6.x requires PHP 8.1+)
#   - Keep monolog at 1.25.3 (2.x required by browscap 6.x)
log "Patching composer.json for PHP 7.4 compatibility..."
python3 - <<'PYEOF'
import json, sys
path = '/var/www/MISP/app/composer.json'
try:
    c = json.load(open(path))
except Exception as e:
    print(f"Could not read composer.json: {e}")
    sys.exit(0)
c['require']['php']                    = '>=7.4.0'
c['require']['browscap/browscap-php'] = '5.1.0'
c['require']['monolog/monolog']        = '1.25.3'
json.dump(c, open(path, 'w'), indent=4)
print("composer.json patched")
PYEOF

log "Running composer install (PHP 7.4)..."
cd "${MISP_DIR}/app"
HOME=/root COMPOSER_ALLOW_SUPERUSER=1 \
  "${PHP74_BIN}" /usr/local/bin/composer install \
  --no-dev --no-interaction \
  --ignore-platform-req=ext-pcntl \
  --quiet \
  2>/dev/null \
  || log "WARNING: Composer install had errors — continuing"

# Install Python dependencies
log "Installing MISP Python dependencies..."
pip3 install pymisp pyzmq redis requests cryptography bcrypt \
  >/dev/null 2>&1 || log "WARNING: Some Python deps failed — non-fatal"

echo ""

# ---------------------------------------------------------------------------
# STEP 9 — Apache HTTPS vhost with PHP 7.4 FPM handler
# ---------------------------------------------------------------------------
log "=== STEP 9: Configuring Apache HTTPS vhost ==="

SSL_DIR="/etc/ssl/misp"
mkdir -p "${SSL_DIR}"

if [[ ! -f "${SSL_DIR}/misp.key" ]]; then
  openssl req -x509 -newkey rsa:2048 \
    -keyout "${SSL_DIR}/misp.key" \
    -out    "${SSL_DIR}/misp.crt" \
    -days 3650 -nodes \
    -subj "/C=US/ST=California/L=San Jose/O=BigChemistry/CN=misp.bc-ctrl.internal" \
    -addext "subjectAltName=DNS:misp.bc-ctrl.internal" \
    2>/dev/null \
    || fail "TLS cert generation failed"
  chmod 600 "${SSL_DIR}/misp.key"
  chmod 644 "${SSL_DIR}/misp.crt"
fi

# Disable system PHP-FPM (uses PHP 8.x — conflicts with MISP)
systemctl stop php-fpm  2>/dev/null || true
systemctl disable php-fpm 2>/dev/null || true

# Disable default SSL listener to avoid port 443 conflict
sed -i 's/^Listen 443 https/#Listen 443 https/' /etc/httpd/conf.d/ssl.conf 2>/dev/null || true

cat > /etc/httpd/conf.d/misp.conf <<EOF
Listen 443 https

<VirtualHost *:443>
    ServerName misp.bc-ctrl.internal
    DocumentRoot ${MISP_DIR}/app/webroot

    SSLEngine on
    SSLCertificateFile    ${SSL_DIR}/misp.crt
    SSLCertificateKeyFile ${SSL_DIR}/misp.key
    SSLProtocol           all -SSLv2 -SSLv3 -TLSv1 -TLSv1.1
    SSLCipherSuite        HIGH:!ADH:!EXP:!MD5:!RC4:!3DES:!CAMELLIA:@STRENGTH
    SSLHonorCipherOrder   on

    # Route .php files to PHP 7.4 FPM (not the system PHP 8.x FPM)
    <FilesMatch \\.php\$>
        SetHandler "proxy:unix:${PHP74_SOCK}|fcgi://localhost"
    </FilesMatch>

    <Directory ${MISP_DIR}/app/webroot>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

    <Directory ${MISP_DIR}/app>
        Options -Indexes
    </Directory>

    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set X-XSS-Protection "1; mode=block"
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"

    ErrorLog  /var/log/httpd/misp-error.log
    CustomLog /var/log/httpd/misp-access.log combined
</VirtualHost>

<VirtualHost *:80>
    ServerName misp.bc-ctrl.internal
    RewriteEngine On
    RewriteRule ^/?(.*) https://%{SERVER_NAME}/\$1 [R=301,L]
</VirtualHost>
EOF

log "Apache vhost written."
echo ""

# ---------------------------------------------------------------------------
# STEP 10 — Configure MISP (database.php and config.php)
# ---------------------------------------------------------------------------
log "=== STEP 10: Configuring MISP ==="

MISP_CONFIG_DIR="${MISP_DIR}/app/Config"

# Force-write database.php with 127.0.0.1 (not localhost — avoids Unix socket lookup)
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

[[ -f "${MISP_CONFIG_DIR}/bootstrap.php" ]] \
  || cp "${MISP_CONFIG_DIR}/bootstrap.default.php" "${MISP_CONFIG_DIR}/bootstrap.php"
[[ -f "${MISP_CONFIG_DIR}/core.php" ]] \
  || cp "${MISP_CONFIG_DIR}/core.default.php" "${MISP_CONFIG_DIR}/core.php"

# Write config.php — patch baseurl and security salt
[[ -f "${MISP_CONFIG_DIR}/config.php" ]] \
  || cp "${MISP_CONFIG_DIR}/config.default.php" "${MISP_CONFIG_DIR}/config.php"

python3 - <<PYEOF
import re
path = '${MISP_CONFIG_DIR}/config.php'
with open(path, 'r') as f:
    content = f.read()
content = re.sub(r"'baseurl'\s*=>\s*'[^']*'", "'baseurl' => '${MISP_BASEURL}'", content)
content = re.sub(r"'salt'\s*=>\s*'[^']*'",    "'salt'    => '${SECURITY_SALT}'",  content)
with open(path, 'w') as f:
    f.write(content)
print("config.php patched")
PYEOF

# Security salt in core.php
sed -i "s/Security.salt.*/Security.salt', '${SECURITY_SALT}');/" \
  "${MISP_CONFIG_DIR}/core.php" 2>/dev/null || true

log "MISP config files written."
echo ""

# ---------------------------------------------------------------------------
# STEP 11 — File storage symlink and ownership
# ---------------------------------------------------------------------------
log "=== STEP 11: MISP file storage setup ==="

if [[ -d "${MISP_DIR}/app/files" && ! -L "${MISP_DIR}/app/files" ]]; then
  rsync -a "${MISP_DIR}/app/files/" "${MISP_FILES}/" 2>/dev/null || true
  rm -rf "${MISP_DIR}/app/files"
fi
[[ -L "${MISP_DIR}/app/files" ]] \
  || ln -s "${MISP_FILES}" "${MISP_DIR}/app/files"

chown -R apache:apache "${MISP_DIR}" "${MISP_FILES}" 2>/dev/null || true
find "${MISP_DIR}" -type f -exec chmod 0640 {} \; 2>/dev/null || true
find "${MISP_DIR}" -type d -exec chmod 0750 {} \; 2>/dev/null || true
chmod +x "${MISP_DIR}/app/Console/cake" 2>/dev/null || true

if command -v semanage >/dev/null 2>&1; then
  semanage fcontext -a -t httpd_sys_rw_content_t "${MISP_DIR}/app/tmp(/.*)?"    2>/dev/null || true
  semanage fcontext -a -t httpd_sys_rw_content_t "${MISP_DIR}/app/files(/.*)?"  2>/dev/null || true
  semanage fcontext -a -t httpd_sys_rw_content_t "${MISP_FILES}(/.*)?"          2>/dev/null || true
  semanage fcontext -a -t httpd_sys_rw_content_t "${MISP_DIR}/app/Config(/.*)?" 2>/dev/null || true
  restorecon -Rv "${MISP_DIR}" "${MISP_FILES}" 2>/dev/null || true
fi
echo ""

# ---------------------------------------------------------------------------
# STEP 12 — Enable services
# ---------------------------------------------------------------------------
log "=== STEP 12: Starting services ==="
systemctl enable --now httpd     || fail "Failed to enable httpd"
systemctl enable --now mysqld    2>/dev/null || true
systemctl enable --now "${REDIS_SVC}" 2>/dev/null || true
systemctl restart php74-fpm      || fail "Failed to restart php74-fpm"
systemctl restart httpd          || fail "Failed to restart httpd"
log "All services running."
echo ""

# ---------------------------------------------------------------------------
# STEP 13 — MISP database schema + admin user (first boot only)
# ---------------------------------------------------------------------------
log "=== STEP 13: MISP database schema initialisation ==="

TABLE_COUNT="$(mysql -u root -p"${MYSQL_ROOT_PASSWORD}" -D misp \
  -se "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='misp';" \
  2>/dev/null || echo "0")"

if [[ "${TABLE_COUNT}" -lt 10 ]]; then
  log "Importing MISP base schema..."
  mysql -u root -p"${MYSQL_ROOT_PASSWORD}" misp \
    < "${MISP_DIR}/INSTALL/MYSQL.sql" 2>/dev/null \
    || log "WARNING: MYSQL.sql import had errors — check manually"

  # Seed admin user (MISP hashes: SHA1(salt + SHA1(password)))
  log "Seeding MISP admin user: ${MISP_ADMIN_EMAIL}"
  ADMIN_SALT="$(python3 -c "import secrets, string; print(secrets.token_hex(16))")"
  ADMIN_HASH="$(python3 -c "
import hashlib
salt = '${ADMIN_SALT}'
pw   = '${MISP_ADMIN_PASSPHRASE}'
inner = hashlib.sha1(pw.encode()).hexdigest()
outer = hashlib.sha1((salt + inner).encode()).hexdigest()
print(outer)
")"

  mysql -u root -p"${MYSQL_ROOT_PASSWORD}" misp 2>/dev/null <<SQL || true
INSERT IGNORE INTO organisations (id, name, uuid, date_created, date_modified, type, local)
  VALUES (1, 'BigChemistry', '$(python3 -c "import uuid; print(str(uuid.uuid4()))")', NOW(), NOW(), 'ADMIN', 1);

INSERT IGNORE INTO users
  (id, org_id, email, password, password_salt, authkey,
   role_id, change_pw, termsaccepted, newsread,
   date_created, date_modified)
VALUES
  (1, 1, '${MISP_ADMIN_EMAIL}', '${ADMIN_HASH}', '${ADMIN_SALT}',
   '$(python3 -c "import secrets, string; chars=string.ascii_letters+string.digits; print(''.join(secrets.choice(chars) for _ in range(40)))")',
   1, 0, 1, 1,
   UNIX_TIMESTAMP(), UNIX_TIMESTAMP());
SQL
  log "Admin user seeded."
else
  log "MISP DB already has ${TABLE_COUNT} tables — skipping schema init."
fi
echo ""

# ---------------------------------------------------------------------------
# STEP 14 — Verify MISP responds
# ---------------------------------------------------------------------------
log "=== STEP 14: Verifying MISP endpoint ==="

MISP_OK=false
for i in $(seq 1 24); do
  HTTP_CODE="$(curl -sk -o /dev/null -w "%{http_code}" \
    --resolve "misp.bc-ctrl.internal:443:127.0.0.1" \
    "https://misp.bc-ctrl.internal/users/login" \
    --connect-timeout 5 --max-time 10 2>/dev/null || echo "000")"
  if [[ "${HTTP_CODE}" == "200" ]]; then
    log "MISP responding: HTTP 200 (after $((i * 5))s)"
    MISP_OK=true
    break
  fi
  log "  Attempt ${i}/24: HTTP ${HTTP_CODE} — waiting..."
  sleep 5
done

"${MISP_OK}" || log "WARNING: MISP did not return 200 within 120s — check /var/log/httpd/misp-error.log"

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
echo "    httpd      — $(systemctl is-active httpd        2>/dev/null || echo unknown)"
echo "    mysqld     — $(systemctl is-active mysqld       2>/dev/null || echo unknown)"
echo "    redis      — $(systemctl is-active "${REDIS_SVC}" 2>/dev/null || echo unknown)"
echo "    php74-fpm  — $(systemctl is-active php74-fpm   2>/dev/null || echo unknown)"
echo ""
echo "  PHP version: $("${PHP74_BIN}" --version 2>/dev/null | head -1)"
echo "  MISP URL:    ${MISP_BASEURL}"
echo "  Admin email: ${MISP_ADMIN_EMAIL}"
echo ""
echo "  Post-install:"
echo "    1. Log in at ${MISP_BASEURL}/users/login"
echo "    2. Administration → Auth Keys → create a new API key"
echo "    3. Update bc/suricata/misp and bc/zeek/misp in Secrets Manager"
echo "       with the new API key, then restart Suricata and Zeek pods"
echo "=============================================================="

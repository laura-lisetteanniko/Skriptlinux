#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------
# WordPress automaatne paigaldus Debian/Ubuntu (Bookworm, Jammy jne)
# ---------------------------------------------
# Käivita: sudo ./wordpress_paigaldus.sh
# Või muuda vaikimisi väärtusi allpool.

# --- Kasutaja määratavad parameetrid ---
DB_NAME="${DB_NAME:-wordpress}"
DB_USER="${DB_USER:-wpuser}"
DB_PASS="${DB_PASS:-qwerty}"
DB_HOST="${DB_HOST:-localhost}"
SITE_DOMAIN="${SITE_DOMAIN:-localhost}"
WEBROOT="${WEBROOT:-/var/www/wordpress}"
APACHE_SITE="${APACHE_SITE:-wordpress.conf}"
WP_CLI_INSTALL="${WP_CLI_INSTALL:-false}"  # lisa --wp-cli kui soovid wp-cli

# --- Argumendid CLI kaudu ---
while [[ $# -gt 0 ]]; do
  case "$1" in
    --db-name) DB_NAME="$2"; shift 2;;
    --db-user) DB_USER="$2"; shift 2;;
    --db-pass) DB_PASS="$2"; shift 2;;
    --db-host) DB_HOST="$2"; shift 2;;
    --site|--domain) SITE_DOMAIN="$2"; shift 2;;
    --webroot) WEBROOT="$2"; shift 2;;
    --wp-cli) WP_CLI_INSTALL="true"; shift 1;;
    *) echo "Tundmatu argument: $1"; exit 1;;
  esac
done

# --- Abifunktsioonid ---
need_root() {
  if [[ "$EUID" -ne 0 ]]; then
    echo "Palun käivita skript sudo'ga." >&2
    exit 1
  fi
}

pkg_installed() {
  dpkg -s "$1" &>/dev/null
}

install_if_missing() {
  local pkgs=("$@")
  local missing=()
  for p in "${pkgs[@]}"; do
    if ! pkg_installed "$p"; then
      missing+=("$p")
    fi
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Paigaldan paketid: ${missing[*]}"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
  fi
}

service_enable_start() {
  systemctl enable "$1"
  systemctl restart "$1"
  echo "Teenuse $1 olek:"
  systemctl --no-pager --full status "$1" | sed -n '1,5p' || true
}

# --- 1) Eeltingimused ---
need_root

echo "Kontrollin ja paigaldan vajalikud paketid..."
install_if_missing git wget curl unzip ca-certificates apache2
install_if_missing php libapache2-mod-php php-mysql php-xml php-curl php-gd php-zip php-mbstring

# --- 2) MariaDB/MySQL ---
if apt-cache show mariadb-server >/dev/null 2>&1; then
  DB_SERVER_PKG="mariadb-server"
  DB_SERVICE="mariadb"
else
  DB_SERVER_PKG="default-mysql-server"
  DB_SERVICE="mysql"
fi

install_if_missing "${DB_SERVER_PKG}"
service_enable_start "${DB_SERVICE}"

# vali kliendikäsk
DB_CLIENT_BIN="${DB_CLIENT_BIN:-$(command -v mariadb || command -v mysql)}"
if [[ -z "${DB_CLIENT_BIN}" ]]; then
  echo "Puudub mysql/mariadb kliendikäsk." >&2; exit 1
fi

mysql_can_login() {
  # Debiani/MariaDB vaikimisi: root UNIX-socketiga
  if "${DB_CLIENT_BIN}" -u root -e "SELECT 1;" &>/dev/null; then
    echo "socket"
    return 0
  fi
  # Kui vaja, küsi parool
  echo -n "Sisesta MySQL/MariaDB root parool: "
  read -rs MYSQL_ROOT_PASSWORD; echo
  if "${DB_CLIENT_BIN}" -u root -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1;" &>/dev/null; then
    echo "password"
    return 0
  fi
  return 1
}

mysql_exec() {
  local mode="$1"; shift
  case "$mode" in
    socket)   "${DB_CLIENT_BIN}" -u root -e "$*";;
    password) "${DB_CLIENT_BIN}" -u root -p"${MYSQL_ROOT_PASSWORD}" -e "$*";;
    *) echo "Tundmatu DB režiim"; exit 1;;
  esac
}

echo "Kontrollin andmebaasiühendust..."
if ! LOGIN_MODE=$(mysql_can_login); then
  echo "Ei saanud MySQL/MariaDB ühendust." >&2
  exit 1
fi

echo "Loon andmebaasi ja kasutaja (kui puudub)..."
mysql_exec "$LOGIN_MODE" "CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"
mysql_exec "$LOGIN_MODE" "CREATE USER IF NOT EXISTS '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${DB_PASS}';"
mysql_exec "$LOGIN_MODE" "ALTER USER '${DB_USER}'@'${DB_HOST}' IDENTIFIED BY '${DB_PASS}';"
mysql_exec "$LOGIN_MODE" "GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${DB_HOST}'; FLUSH PRIVILEGES;"

# --- 3) WordPress allalaadimine ---
echo "Valmistan webrooti: ${WEBROOT}"
mkdir -p "${WEBROOT}"
cd /tmp
echo "Laen alla WordPressi..."
wget -q https://wordpress.org/latest.tar.gz -O latest.tar.gz
tar xzf latest.tar.gz
rsync -a wordpress/ "${WEBROOT}/"

# --- 4) wp-config.php seadistus ---
cd "${WEBROOT}"
if [[ ! -f wp-config.php ]]; then
  cp wp-config-sample.php wp-config.php
fi

sed -i "s/define( *'DB_NAME'.*/define( 'DB_NAME', '${DB_NAME}' );/g" wp-config.php
sed -i "s/define( *'DB_USER'.*/define( 'DB_USER', '${DB_USER}' );/g" wp-config.php
sed -i "s/define( *'DB_PASSWORD'.*/define( 'DB_PASSWORD', '${DB_PASS}' );/g" wp-config.php
sed -i "s/define( *'DB_HOST'.*/define( 'DB_HOST', '${DB_HOST}' );/g" wp-config.php

# Lisa turvasoolad
echo "Uuendan turvasoolad..."
if SALTS=$(curl -fsS https://api.wordpress.org/secret-key/1.1/salt/); then
  esc_salts=$(printf '%s\n' "$SALTS" | sed -e 's/[\/&]/\\&/g')
  sed -i "/AUTH_KEY/,$ d" wp-config.php
  printf "%s\n" "$esc_salts" >> wp-config.php
fi

# --- Failiõigused ---
chown -R www-data:www-data "${WEBROOT}"
find "${WEBROOT}" -type d -exec chmod 755 {} \;
find "${WEBROOT}" -type f -exec chmod 644 {} \;

# --- 5) Apache virtuaalhost ---
echo "Seadistan Apache virtuaalhosti..."
cat >/etc/apache2/sites-available/${APACHE_SITE} <<EOF
<VirtualHost *:80>
    ServerName ${SITE_DOMAIN}
    DocumentRoot ${WEBROOT}

    <Directory ${WEBROOT}>
        AllowOverride All
        Require all granted
    </Directory>

    ErrorLog \${APACHE_LOG_DIR}/${SITE_DOMAIN}_error.log
    CustomLog \${APACHE_LOG_DIR}/${SITE_DOMAIN}_access.log combined
</VirtualHost>
EOF

a2enmod rewrite >/dev/null
a2ensite "${APACHE_SITE}" >/dev/null
if [[ "${SITE_DOMAIN}" != "localhost" ]]; then
  a2dissite 000-default >/dev/null || true
fi

service_enable_start apache2

# --- 6) (Valikuline) wp-cli ---
if [[ "${WP_CLI_INSTALL}" == "true" ]]; then
  echo "Paigaldan wp-cli..."
  curl -fsSLo /usr/local/bin/wp https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
  chmod +x /usr/local/bin/wp
  echo "wp-cli paigaldatud."
fi

# --- 7) Lõpusõnum ---
echo
echo "---------------------------------------------"
echo "WordPress edukalt paigaldatud!"
echo "Ava brauseris: http://${SITE_DOMAIN}"
echo "Dokumendijuur: ${WEBROOT}"
echo "Andmebaas: ${DB_NAME}"
echo "Kasutaja: ${DB_USER}"
echo "---------------------------------------------"

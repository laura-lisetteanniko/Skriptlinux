#!/usr/bin/env bash
# mysql-paigaldus.sh
# Debian 12: Oracle MySQL Server 8.x paigaldus koos repo lisamise,
# MariaDB purge'i, APT pinni, root parooli seadistuse ja tervisekontrolliga.
# Vaikimisi root parool: qwerty (muuda muutujaga MYSQL_ROOT_PASSWORD).

set -euo pipefail

### --- Muutujad ---
MYSQL_APT_DEB_URL="${MYSQL_APT_DEB_URL:-https://dev.mysql.com/get/mysql-apt-config_0.8.36-1_all.deb}"
MYSQL_APT_DEB_FILE="${MYSQL_APT_DEB_FILE:-/tmp/mysql-apt-config.deb}"
MYSQL_ROOT_PASSWORD="${MYSQL_ROOT_PASSWORD:-qwerty}"     # MUUDA VAJADUSEL
NONINTERACTIVE="${NONINTERACTIVE:-1}"
### -----------------

if [[ "${NONINTERACTIVE}" -eq 1 ]]; then
  export DEBIAN_FRONTEND=noninteractive
fi

log()  { echo -e "\033[1;32m[INF]\033[0m $*"; }
warn() { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[1;31m[ERR]\033[0m $*" >&2; }

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    err "Käivita root-õigustes: sudo $0"
    exit 1
  fi
}

apt_update_safe() {
  log "Apt pakettide nimekirja värskendamine…"
  if ! apt-get update -y; then
    warn "apt update ebaõnnestus – proovin võtmeid korrastada (legacy meetod)…"
    if command -v apt-key >/dev/null 2>&1; then
      apt-key list || true
      apt-key del A4A9406876FCBD3C456770C88C718D3B5072E1F5 || true
      apt-key adv --keyserver pgp.mit.edu --recv-keys 467B942D3A79BD29 || true
    fi
    apt-get update -y
  fi
}

install_prereqs() {
  log "Eeltingimuste paigaldus (gnupg, ca-certificates, wget, lsb-release, debconf-utils)…"
  apt-get install -y --no-install-recommends gnupg ca-certificates wget lsb-release apt-transport-https debconf-utils
}

add_mysql_repo() {
  if ! apt-cache policy | grep -qi "repo.mysql.com"; then
    log "Laen MySQL APT konfiguratsioonipaki…"
    wget -O "${MYSQL_APT_DEB_FILE}" "${MYSQL_APT_DEB_URL}"
    log "Paigaldan mysql-apt-config…"
    # Vaikeseaded: MySQL 8.x + tööriistad (dpkg võib küsida – noninteractive leevendab)
    dpkg -i "${MYSQL_APT_DEB_FILE}" || true
    apt-get -f install -y
  else
    log "MySQL APT repositoorium juba lisatud."
  fi

  log "Seadistan APT pinni (eelista repo.mysql.com pakette)…"
  mkdir -p /etc/apt/preferences.d
  cat >/etc/apt/preferences.d/mysql.pref <<'EOF'
Package: *
Pin: origin repo.mysql.com
Pin-Priority: 700
EOF
  apt_update_safe
}

purge_mariadb() {
  log "Eemaldan MariaDB paketid ja default-mysql meta (vältimaks virtual-mysql konflikte)…"
  apt-mark unhold mariadb-client mariadb-server default-mysql-client default-mysql-server 2>/dev/null || true
  apt-get remove --purge -y 'mariadb-*' 'galera-*' 'default-mysql-*' 'mysql-common' || true
  apt-get autoremove -y || true
  apt-get autoclean || true

  # Labikeskkonnas võib puhastada ka kataloogid (NB! kustutab andmed!)
  if [[ "${WIPE_MYSQL_DIRS:-0}" -eq 1 ]]; then
    rm -rf /etc/mysql /var/lib/mysql || true
  fi
}

preseed_root_password() {
  log "Seadistan debconf’iga root parooli automaatseks installiks…"
  echo "mysql-community-server mysql-community-server/root-pass password ${MYSQL_ROOT_PASSWORD}" | debconf-set-selections
  echo "mysql-community-server mysql-community-server/re-root-pass password ${MYSQL_ROOT_PASSWORD}" | debconf-set-selections
  # Ajaloolistele võtmetele ka:
  echo "mysql-server mysql-server/root_password password ${MYSQL_ROOT_PASSWORD}" | debconf-set-selections || true
  echo "mysql-server mysql-server/root_password_again password ${MYSQL_ROOT_PASSWORD}" | debconf-set-selections || true
}

install_mysql() {
  log "Paigaldan MySQL Serveri ja abipaketid…"
  apt-get install -y mysql-server mysql-client mysql-shell
}

enable_and_start() {
  log "Luban ja käivitan teenuse…"
  systemctl daemon-reload || true
  systemctl enable --now mysql
  systemctl is-active --quiet mysql || { err "MySQL teenus ei tööta"; journalctl -u mysql -e | tail -n50; exit 1; }
}

configure_root_access() {
  log "Root-kasutaja ligipääsu seadistamine…"
  local PASS_OK=0

  # Kui socketiga saab sisse, pane parool
  if mysql -uroot -e "SELECT 1;" >/dev/null 2>&1; then
    mysql -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASSWORD}';
FLUSH PRIVILEGES;
SQL
    PASS_OK=1
  else
    # proovi kohe parooliga, kui debconf juba rakendus
    if mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "SELECT 1;" >/dev/null 2>&1; then
      PASS_OK=1
    fi
  fi

  # /root/.my.cnf mugavuseks
  if [[ ${PASS_OK} -eq 1 ]]; then
    log "Loon /root/.my.cnf (õigused 600)…"
    umask 177
    cat >/root/.my.cnf <<EOF
[client]
user=root
password=${MYSQL_ROOT_PASSWORD}
host=localhost
EOF
  else
    warn "Root parooli ei kinnitatud automaatselt. Proovi: sudo mysql ja sea parool käsitsi."
  fi
}

health_check() {
  log "Tervisekontroll…"
  mysql --version || { err "mysql kliendi versioon puudub"; exit 1; }
  systemctl status mysql --no-pager | sed -n '1,12p' || true

  # Loo testbaas, kirjuta/loe, kustuta
  if mysql -uroot -p"${MYSQL_ROOT_PASSWORD}" -e "CREATE DATABASE IF NOT EXISTS install_test; CREATE TABLE IF NOT EXISTS install_test.ping(id INT PRIMARY KEY, note VARCHAR(64)); INSERT INTO install_test.ping VALUES (1,'ok') ON DUPLICATE KEY UPDATE note='ok'; SELECT * FROM install_test.ping; DROP DATABASE install_test;" ; then
    log "DB ühendus ja CRUD test OK."
  else
    warn "Parooliga ühendus ei õnnestunud – kontrolli autentimist (auth_socket vs native_password)."
  fi
}

print_summary() {
  cat <<TXT

================= Kokkuvõte =================
MySQL Server on paigaldatud ja töötab.

Kasulikud käsud:
  systemctl status mysql
  journalctl -u mysql -e
  mysql --version
  mysql -uroot -p

Failid:
  /root/.my.cnf  (root kliendi vaikekonf – õigused 600)

Root parool (selles installis): ${MYSQL_ROOT_PASSWORD}

Deinstall / puhastus:
  $0 --purge
============================================
TXT
}

purge_all() {
  warn "Eemaldan MySQL’i ja repositooriumi (PURGE)…"
  systemctl stop mysql 2>/dev/null || true
  apt-get remove --purge -y mysql-server mysql-client mysql-common mysql-shell || true
  apt-get autoremove -y || true
  apt-get autoclean || true
  apt-get remove -y mysql-apt-config || true
  apt-get purge -y mysql-apt-config || true
  rm -rf /etc/apt/preferences.d/mysql.pref /var/lib/apt/lists/* || true
  # Soovi korral puhasta ka kataloogid
  if [[ "${WIPE_MYSQL_DIRS:-1}" -eq 1 ]]; then
    rm -rf /etc/mysql /var/lib/mysql || true
  fi
  log "Puhastus tehtud. Soovitus: reboot"
}

main() {
  require_root

  case "${1:-}" in
    --purge)
      purge_all
      exit 0
      ;;
    *)
      install_prereqs
      add_mysql_repo
      purge_mariadb
      apt_update_safe
      preseed_root_password
      install_mysql
      enable_and_start
      configure_root_access
      health_check
      print_summary
      ;;
  esac
}

main "$@"

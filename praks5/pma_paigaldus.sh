#!/usr/bin/env bash
# pma_paigaldus.sh – phpMyAdmini (koos Apache, PHP ja MariaDB-ga) paigaldus Debian/Ubuntu süsteemidesse
# Kasutus:
#   sudo ./pma_paigaldus.sh          # interaktiivne (debconf küsib webserveri valikut)
#   sudo ./pma_paigaldus.sh --auto   # mitte-interaktiivne (valib automaatselt apache2, DB seadistus käsitsi hiljem)

set -euo pipefail

GREEN="\e[32m"; YELLOW="\e[33m"; RED="\e[31m"; BOLD="\e[1m"; RESET="\e[0m"
info(){ echo -e "${YELLOW}[INFO]${RESET} $*"; }
ok(){ echo -e "${GREEN}[OK]${RESET} $*"; }
err(){ echo -e "${RED}[VIGA]${RESET} $*"; }

if [[ "${EUID}" -ne 0 ]]; then
  err "Palun käivita root-õigustes (nt: sudo $0)."
  exit 1
fi

AUTO=0
if [[ "${1:-}" == "--auto" ]]; then
  AUTO=1
  export DEBIAN_FRONTEND=noninteractive
fi

info "Kontrollin, et tegemist on Debian/Ubuntu-laadse süsteemiga…"
if ! command -v apt >/dev/null 2>&1; then
  err "Selle skripti jaoks on vaja apt-pakihaldurit (Debian/Ubuntu)."
  exit 1
fi
ok "apt on olemas."

info "Uuendan paketiloendid…"
apt update -y
ok "Paketiloendid uuendatud."

info "Paigaldan abipaketid (debconf-utils, software-properties-common)…"
apt install -y debconf-utils software-properties-common lsb-release ca-certificates >/dev/null
ok "Abipaketid paigaldatud."

info "Paigaldan Apache veebiserveri…"
apt install -y apache2
systemctl enable --now apache2
ok "Apache paigaldatud ja käivitatud."

info "Paigaldan PHP ja vajalike laiendustega…"
apt install -y php libapache2-mod-php php-mysql php-mbstring php-zip php-gd php-json php-curl php-xml
phpenmod mbstring >/dev/null || true
ok "PHP koos laiendustega paigaldatud."

info "Paigaldan MariaDB serveri ja kliendi…"
apt install -y mariadb-server mariadb-client
systemctl enable --now mariadb
ok "MariaDB paigaldatud ja käivitatud."

if [[ "${AUTO}" -eq 1 ]]; then
  info "Eelseadistan phpMyAdmini (mitte-interaktiivne režiim)…"
  # Seo phpMyAdmin Apache'iga; DB automaathäälestust EI tehta (teed hiljem ise).
  echo "phpmyadmin phpmyadmin/reconfigure-webserver multiselect apache2" | debconf-set-selections
  echo "phpmyadmin phpmyadmin/dbconfig-install boolean false" | debconf-set-selections
fi

info "Paigaldan phpMyAdmini…"
apt install -y phpmyadmin

# Mõnes süsteemis peab konf eraldi lubama:
if [ -f /etc/apache2/conf-available/phpmyadmin.conf ]; then
  a2enconf phpmyadmin >/dev/null || true
fi

info "Taaskäivitan Apache, et laadida PHP ja phpMyAdmini konf…"
systemctl reload apache2
ok "Apache taaskäivitatud."

# Lihtne kontroll
PMACHECK_URL="http://127.0.0.1/phpmyadmin"
info "Kontrollin, kas phpMyAdmin vastab: ${PMACHECK_URL}"
if command -v curl >/dev/null 2>&1; then
  if curl -s -I "${PMACHECK_URL}" | head -n1 | grep -q "200\|301\|302"; then
    ok "phpMyAdmin paistab kättesaadav (${PMACHECK_URL})."
  else
    info "phpMyAdmin ei vastanud oodatult. Kontrolli Apache logisid: /var/log/apache2/error.log"
  fi
else
  info "curl puudub; vaata brauseris: ${PMACHECK_URL}"
fi

echo -e "\n${BOLD}VALMIS!${RESET}
- Brauser: ${BOLD}http://SERVERI_IP/phpmyadmin${RESET}
- Kui kasutasid --auto, tee DB sidumine hiljem käsitsi (kasuta olemasolevat MariaDB root-kontot vms).
- Apache logid: ${BOLD}/var/log/apache2/error.log${RESET}
- MariaDB staatus: ${BOLD}systemctl status mariadb${RESET}
"

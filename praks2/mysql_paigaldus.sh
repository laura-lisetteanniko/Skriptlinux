#!/bin/bash

# Skripti nimi: mysql_paigaldus.sh
# Eesmärk: Kontrollib, kas MySQL-server on paigaldatud.
# Kui ei ole, paigaldab selle. Kui on, näitab staatust.

PACKAGE="mariadb-server"
STATUS_CMD="sudo systemctl status mariadb"
CHECK_CMD="dpkg-query -W -f='${Status}' $PACKAGE"

echo "=== MySQL-serveri paigaldamise kontroll ja haldus ==="

# 1. Kontrolli, kas MySQL-server on paigaldatud
# dpkg-query väljundist otsitakse ridade arvu, kus on "ok installed".
INSTALL_STATUS=$( $CHECK_CMD 2>/dev/null | grep -c "ok installed" )

if [ "$INSTALL_STATUS" -eq 1 ]; then
    # 2. MySQL-server on paigaldatud
    echo "✅ Teenus '$PACKAGE' on juba paigaldatud."
    echo "--------------------------------------------------------"
    echo "Staatuse väljund: "
    $STATUS_CMD
    echo "--------------------------------------------------------"
elif [ "$INSTALL_STATUS" -eq 0 ]; then
    # 3. MySQL-server ei ole paigaldatud - alusta paigaldust
    echo "❌ Teenus '$PACKAGE' ei ole paigaldatud. Alustan paigaldust..."

    # 3.1 Värskenda pakettide loetelu (eraldi sammuna)
    echo "Käivitan: sudo apt update"
    sudo apt update
    
    # Kontrolli, kas uuendus õnnestus
    if [ $? -ne 0 ]; then
        echo "❌ Pakettide loetelu värskendamine (apt update) ebaõnnestus. Lõpetan."
        echo "--------------------------------------------------------"
        exit 1
    fi

    # 3.2 Paigalda teenus
    echo "Käivitan: sudo apt install -y $PACKAGE"
    sudo apt install -y $PACKAGE
    
    # Kontrolli paigalduse õnnestumist
    if [ $? -eq 0 ]; then
        echo "✅ '$PACKAGE' paigaldamine õnnestus."
        echo "--------------------------------------------------------"
        echo "Staatuse väljund (pärast paigaldust): "
        $STATUS_CMD
        echo "--------------------------------------------------------"
    else
        echo "❌ '$PACKAGE' paigaldamine ebaõnnestus. Palun kontrolli vigu."
        echo "--------------------------------------------------------"
    fi
else
    # Ootamatu dpkg-query väljund
    echo "⚠️ Kontrollimisel tekkis ootamatu olukord."
    echo "Võimalik, et pakett on poolikult paigaldatud või esineb viga."
    echo "--------------------------------------------------------"
fi

echo "=== Lõpetatud ==="

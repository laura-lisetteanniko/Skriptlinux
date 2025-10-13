#!/bin/bash

# Skripti nimi: apache_paigaldus.sh
# Eesmärk: Kontrollib, kas Apache2 on paigaldatud.
# Kui ei ole, paigaldab selle. Kui on, näitab staatust.

PACKAGE="apache2"
STATUS_CMD="sudo systemctl status $PACKAGE"
CHECK_CMD="dpkg-query -W -f='${Status}' $PACKAGE"

echo "=== Apache2 teenuse paigaldamise kontroll ja haldus ==="

# 1. Kontrolli, kas Apache2 on paigaldatud
# dpkg-query väljundi filtreerimine (grep -c) loeb ridade arvu, kus on "ok installed".
# Väärtus 1 näitab, et pakett on paigaldatud.
INSTALL_STATUS=$( $CHECK_CMD 2>/dev/null | grep -c "ok installed" )

if [ "$INSTALL_STATUS" -eq 1 ]; then
    # 2. Apache2 on paigaldatud
    echo "✅ Teenus '$PACKAGE' on juba paigaldatud."
    echo "--------------------------------------------------------"
    echo "Staatuse väljund: "
    $STATUS_CMD
    echo "--------------------------------------------------------"
elif [ "$INSTALL_STATUS" -eq 0 ]; then
    # 3. Apache2 ei ole paigaldatud - alusta paigaldust
    echo "❌ Teenus '$PACKAGE' ei ole paigaldatud. Alustan paigaldust..."

    # Viga: "E: The update command takes no arguments" lahendatakse 
    # apt update ja apt install eraldi käivitades.
    
    # 3.1 Värskenda pakettide loetelu
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

#!/bin/zsh
# Один раз создаёт постоянный сертификат подписи «NotchFlow Local Signing» в связке login.
# С ним каждая сборка подписывается одинаково, и macOS не сбрасывает разрешения
# («Универсальный доступ» и т. п.) при обновлении. Пароль Mac спросится дважды:
# разрешить ключ для codesign и доверять сертификату для подписи кода.
set -euo pipefail

NAME="NotchFlow Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
    echo "Сертификат «$NAME» уже настроен"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
PASS=$(openssl rand -hex 16)

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout "pass:$PASS"

# Ключ доступен только codesign; в связку попадают сертификат и закрытый ключ.
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign

# Без списка разделов macOS спрашивает пароль связки при КАЖДОЙ подписи (с macOS 10.12),
# а сборка в фоне зависает в ожидании ответа. Пароль Mac спросится здесь один раз.
echo "Сейчас macOS попросит пароль Mac, чтобы codesign мог брать ключ без вопросов…"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "<key>" "$KEYCHAIN" >/dev/null

echo "Сейчас macOS попросит пароль, чтобы доверять сертификату для подписи кода…"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"

security find-identity -v -p codesigning | grep "$NAME"
echo "Готово. Следующие сборки будут подписаны «$NAME»."

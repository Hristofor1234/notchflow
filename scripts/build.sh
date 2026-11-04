#!/bin/zsh
# Собирает .build/NotchFlow.app (release, arm64) и подписывает ad-hoc.
# Папка .build скрытая, поэтому сборка не появляется в Spotlight рядом с установленной версией.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
acquire_lock
trap release_lock EXIT

swift build -c release --arch arm64

APP=.build/NotchFlow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/arm64-apple-macosx/release/NotchFlow "$APP/Contents/MacOS/NotchFlow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M%S)" "$APP/Contents/Info.plist"
# Постоянный сертификат (scripts/setup-signing.sh) сохраняет разрешения macOS между обновлениями;
# без него — ad-hoc подпись, и «Универсальный доступ» придётся выдавать после каждой установки.
IDENTITY="NotchFlow Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    codesign --force --sign "$IDENTITY" "$APP"
else
    echo "Подпись ad-hoc: сертификат «$IDENTITY» не настроен (./scripts/setup-signing.sh)"
    codesign --force --sign - "$APP"
fi
echo "Собрано: $PWD/$APP"

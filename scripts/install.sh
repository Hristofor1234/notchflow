#!/bin/zsh
# Собирает NotchFlow и ставит его в /Applications.
#  1. Самопроверка настроек — без неё не ставим.
#  2. Новая версия сразу сохраняется в releases/<версия>-<сборка>/ (приложение + исходники).
#  3. Уходящая версия сохраняется в свою папку вместе со снимком настроек, .app — в Корзину.
#  4. Обе папки отправляются на сервер backup; там хранятся все версии.
# Откат на любую версию: ./scripts/rollback.sh
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh
acquire_lock
trap release_lock EXIT

./scripts/build.sh
NEW=.build/NotchFlow.app

if ! "$NEW/Contents/MacOS/NotchFlow" --selftest-prefs; then
    echo "ОШИБКА: самопроверка настроек не пройдена, установка отменена" >&2
    exit 1
fi
if ! "$NEW/Contents/MacOS/NotchFlow" --selftest-reorder >/dev/null; then
    echo "ОШИБКА: перетаскивание строк считает порядок неверно, установка отменена" >&2
    exit 1
fi
if ! "$NEW/Contents/MacOS/NotchFlow" --click-test; then
    echo "ОШИБКА: нажатия на чёлку обрабатываются не всегда, установка отменена" >&2
    exit 1
fi

NEW_DIR="$RELEASES/$(release_id "$NEW")"
package_app "$NEW" "$NEW_DIR"
tar -czf "$NEW_DIR/source.tar.gz" --exclude ./.build --exclude ./build --exclude ./releases --exclude .DS_Store .
checksum_dir "$NEW_DIR"

deploy_app "$NEW"
prune_local

TO_BACKUP=("$NEW_DIR")
if [[ -n "$OUTGOING_DIR" ]]; then TO_BACKUP+=("$OUTGOING_DIR"); fi
backup_dirs "${TO_BACKUP[@]}"

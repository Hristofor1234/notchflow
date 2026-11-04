# Общие функции для install.sh и rollback.sh (подключается через source).
#
# Каждая версия хранится в своей папке releases/<версия>-<сборка>/:
#   NotchFlow.zip          — приложение
#   source.tar.gz          — исходники, из которых оно собрано (если есть)
#   prefs-<дата>.plist     — снимок настроек в момент, когда эту версию сменили
#   *.sha256               — контрольные суммы
# Локально хранятся 5 последних папок, на сервере backup — все, без перезаписи.

# tar на macOS не должен добавлять служебные файлы ._* и расширенные атрибуты.
export COPYFILE_DISABLE=1
# UTF-8, чтобы zsh считал кириллицу по символам, а не байтам (выравнивание таблиц).
export LC_CTYPE=en_US.UTF-8

DEST=/Applications/NotchFlow.app
DOMAIN=com.hristofor.notchflow
RELEASES=releases
KEEP_LOCAL=5
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
STAMP=$(date +%Y%m%d-%H%M%S)

# Сервер backup: контейнер 102 на proxmox.
BACKUP_HOST=proxmox
BACKUP_CT=102
BACKUP_ROOT=/srv/backups/notchflow/releases

# Замок от одновременных запусков: два build/install/rollback сразу затирают друг другу
# .build/NotchFlow.app. Вложенный вызов (install → build) замок не берёт повторно.
LOCK_DIR=.build/notchflow-script.lock

acquire_lock() {
    [[ -n "${NOTCHFLOW_LOCK_HELD:-}" ]] && return 0
    mkdir -p .build
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        local pid
        pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || true)
        if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
            echo "Уже идёт другая сборка или установка NotchFlow (PID $pid). Дождитесь её окончания." >&2
            exit 1
        fi
        # Замок остался от прерванного запуска — забираем.
        rm -rf "$LOCK_DIR"
        mkdir "$LOCK_DIR"
    fi
    echo $$ > "$LOCK_DIR/pid"
    export NOTCHFLOW_LOCK_HELD=1
    NOTCHFLOW_LOCK_OWNER=$$
}

release_lock() {
    if [[ "${NOTCHFLOW_LOCK_OWNER:-}" == "$$" ]]; then rm -rf "$LOCK_DIR"; fi
}

# «<версия>-<сборка>» для .app.
release_id() {
    # defaults read понимает только абсолютные пути (${1:A}); без версии — ошибка, а не «unknown».
    local plist="${1:A}/Contents/Info" version build
    version=$(defaults read "$plist" CFBundleShortVersionString 2>/dev/null) || { echo "Не прочитать версию $1" >&2; return 1; }
    build=$(defaults read "$plist" CFBundleVersion 2>/dev/null) || { echo "Не прочитать сборку $1" >&2; return 1; }
    echo "$version-$build"
}

# Контрольные суммы для всех файлов папки версии.
checksum_dir() {
    local f
    (
        cd "$1"
        for f in *; do
            [[ -f "$f" && "$f" != *.sha256 ]] || continue
            shasum -a 256 "$f" > "$f.sha256"
        done
    )
}

verify_dir() {
    (cd "$1" && shasum -a 256 -c -- *.sha256 >/dev/null)
}

# Упаковывает .app в папку версии (если её ещё нет).
package_app() {
    mkdir -p "$2"
    if [[ ! -f "$2/NotchFlow.zip" ]]; then
        ditto -c -k --keepParent "$1" "$2/NotchFlow.zip"
    fi
}

prefs_export() {
    defaults export "$DOMAIN" - 2>/dev/null || true
}

# Ставит .app в /Applications. Уходящая версия упаковывается в свою папку вместе со снимком
# настроек, её .app уходит в Корзину. Папка уходящей версии — в OUTGOING_DIR.
# После запуска сверяет, что настройки не изменились (если не задан SKIP_PREFS_CHECK).
deploy_app() {
    local app="$1" prefs_before prefs_after
    OUTGOING_DIR=""

    pkill -x NotchFlow 2>/dev/null || true
    for _ in {1..20}; do pgrep -x NotchFlow >/dev/null || break; sleep 0.25; done

    prefs_before=$(prefs_export)

    if [[ -d "$DEST" ]]; then
        OUTGOING_DIR="$RELEASES/$(release_id "$DEST")"
        package_app "$DEST" "$OUTGOING_DIR"
        if [[ -n "$prefs_before" ]]; then
            defaults export "$DOMAIN" "$OUTGOING_DIR/prefs-$STAMP.plist"
        fi
        checksum_dir "$OUTGOING_DIR"
        "$LSREGISTER" -u "$DEST" 2>/dev/null || true
        mv "$DEST" "$HOME/.Trash/NotchFlow-${OUTGOING_DIR:t}-$STAMP.app"
        echo "Прежняя версия ${OUTGOING_DIR:t} сохранена в $OUTGOING_DIR, .app — в Корзине"
    fi

    ditto "$app" "$DEST"
    "$LSREGISTER" -f "$DEST"

    if [[ -n "${BEFORE_LAUNCH:-}" ]]; then eval "$BEFORE_LAUNCH"; fi

    open "$DEST"
    echo "Установлено: $DEST ($(release_id "$DEST"))"

    if [[ -z "${SKIP_PREFS_CHECK:-}" ]]; then
        sleep 3
        prefs_after=$(prefs_export)
        if [[ "$prefs_before" == "$prefs_after" ]]; then
            echo "Настройки сохранены без изменений"
        else
            echo "ВНИМАНИЕ: настройки изменились. Прежние: ${OUTGOING_DIR:-нет снимка}/prefs-$STAMP.plist" >&2
        fi
    fi
}

# Локально оставляет KEEP_LOCAL самых свежих папок версий (остальные есть на сервере).
prune_local() {
    local old
    # (N/om): только папки, от новых к старым; пустой список, если папок нет.
    local -a dirs=( "$RELEASES"/*(N/om) )
    for old in "${(@)dirs[KEEP_LOCAL+1,-1]}"; do
        mv "$old" "$HOME/.Trash/notchflow-release-${old:t}-$STAMP"
    done
}

# Отправка на backup не должна мешать установке.
backup_dirs() {
    (( $# > 0 )) || return 0
    if ./scripts/backup.sh "$@"; then
        echo "Отправлено на backup: ${(j:, :)${@:t}}"
    else
        echo "ВНИМАНИЕ: не удалось отправить на backup; повторите: ./scripts/backup.sh $*" >&2
    fi
}

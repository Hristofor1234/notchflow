#!/bin/zsh
# Откат NotchFlow на любую сохранённую версию.
#   ./scripts/rollback.sh                          — список версий (сервер backup и локальные)
#   ./scripts/rollback.sh <версия-сборка>          — поставить эту версию; настройки остаются текущими
#   ./scripts/rollback.sh <версия-сборка> --with-prefs — то же, но вернуть и настройки,
#                                                    сохранённые вместе с этой версией
# Если версии нет локально, она скачивается с сервера; контрольные суммы проверяются.
# Текущая версия перед откатом сохраняется так же, как при установке.
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

remote_list() {
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$BACKUP_HOST" \
        "pct exec $BACKUP_CT -- sh -c 'ls -1 $BACKUP_ROOT 2>/dev/null'" 2>/dev/null || true
}

if (( $# == 0 )); then
    current=$( [[ -d "$DEST" ]] && release_id "$DEST" || echo "—" )
    remote=$(remote_list)
    local_ids=$(ls -1 "$RELEASES" 2>/dev/null || true)
    echo "Установлена: $current"
    echo
    # ${(r:N:)…} дополняет пробелами по символам, а не байтам — колонки ровные и с кириллицей.
    print -r -- "${(r:24:)${:-ВЕРСИЯ-СБОРКА}}${(r:8:)${:-СЕРВЕР}}${(r:10:)${:-ЛОКАЛЬНО}}НАСТРОЙКИ"
    for id in $(printf "%s\n%s\n" "$remote" "$local_ids" | grep -v '^$' | sort -u -t- -k1,1V -k2,2n); do
        on_server=$(grep -qx "$id" <<< "$remote" && echo да || echo —)
        on_local=$(grep -qx "$id" <<< "$local_ids" && echo да || echo —)
        snapshots=( "$RELEASES/$id"/prefs-*.plist(N) )
        prefs=$([[ $on_local == да ]] && echo "${#snapshots}" || echo "?")
        mark=$([[ "$id" == "$current" ]] && echo "   ← установлена" || true)
        print -r -- "${(r:24:)id}${(r:8:)on_server}${(r:10:)on_local}${prefs}${mark}"
    done
    [[ -n "$remote" ]] || echo "(сервер backup недоступен — показаны только локальные версии)"
    exit 0
fi

ID=$1
WITH_PREFS=$([[ "${2:-}" == "--with-prefs" ]] && echo 1 || true)
DIR="$RELEASES/$ID"

if [[ "$([[ -d "$DEST" ]] && release_id "$DEST")" == "$ID" && -z "$WITH_PREFS" ]]; then
    echo "Версия $ID уже установлена"
    exit 0
fi

acquire_lock
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; release_lock' EXIT

if [[ ! -f "$DIR/NotchFlow.zip" ]]; then
    echo "Скачиваю $ID с сервера backup…"
    remote_tar="/tmp/notchflow-$ID-$STAMP.tar"
    ssh -o BatchMode=yes -o ConnectTimeout=8 "$BACKUP_HOST" "
        pct exec $BACKUP_CT -- tar -C $BACKUP_ROOT -cf $remote_tar $ID &&
        pct pull $BACKUP_CT $remote_tar $remote_tar &&
        pct exec $BACKUP_CT -- rm -f $remote_tar
    "
    scp -q -o BatchMode=yes "$BACKUP_HOST:$remote_tar" "$TMP/$ID.tar"
    ssh -o BatchMode=yes "$BACKUP_HOST" "rm -f $remote_tar"
    mkdir -p "$RELEASES"
    tar -C "$RELEASES" --keep-old-files -xf "$TMP/$ID.tar" 2>/dev/null || tar -C "$RELEASES" -xkf "$TMP/$ID.tar"
fi

[[ -f "$DIR/NotchFlow.zip" ]] || { echo "Версия $ID не найдена ни локально, ни на сервере" >&2; exit 1; }
verify_dir "$DIR" || { echo "ОШИБКА: контрольные суммы $ID не сходятся, откат отменён" >&2; exit 1; }

ditto -x -k "$DIR/NotchFlow.zip" "$TMP/app"
APP=$(find "$TMP/app" -maxdepth 1 -name "*.app" | head -1)
[[ -n "$APP" ]] || { echo "В архиве $ID нет приложения" >&2; exit 1; }

if [[ -n "$WITH_PREFS" ]]; then
    snapshots=( "$DIR"/prefs-*.plist(N.om) )
    (( ${#snapshots} > 0 )) || { echo "У версии $ID нет сохранённых настроек" >&2; exit 1; }
    PREFS=${snapshots[1]}
    echo "Настройки будут восстановлены из $PREFS"
    # Импорт — после закрытия текущей версии (её настройки уже сохранены в снимок), до запуска.
    BEFORE_LAUNCH="defaults import '$DOMAIN' '$PREFS'"
    SKIP_PREFS_CHECK=1
fi

deploy_app "$APP"
prune_local
if [[ -n "$OUTGOING_DIR" ]]; then backup_dirs "$OUTGOING_DIR"; fi
echo "Откат на $ID выполнен"

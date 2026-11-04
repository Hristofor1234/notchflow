#!/bin/zsh
# Отправляет папки версий на сервер backup: контейнер 102 на proxmox,
# /srv/backups/notchflow/releases/<версия>-<сборка>/.
# Существующие на сервере файлы никогда не перезаписываются (добавляются только новые),
# после загрузки контрольные суммы сверяются на сервере.
# Использование: ./scripts/backup.sh releases/<версия>-<сборка> [ещё папки…]
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/lib.sh

(( $# > 0 )) || { echo "Укажите папку(и) версий для отправки" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for dir in "$@"; do
    dir=${dir%/}
    id=${dir:t}
    payload=( "$dir"/NotchFlow.zip(N) "$dir"/prefs-*.plist(N) )
    (( ${#payload} > 0 )) || { echo "Пустая папка версии: $dir" >&2; exit 1; }
    checksum_dir "$dir"
    tar --no-mac-metadata --no-xattrs -C "${dir:h}" -cf "$TMP/$id.tar" "$id"
    remote_tar="/tmp/notchflow-$id-$STAMP.tar"
    scp -q -o BatchMode=yes -o ConnectTimeout=8 "$TMP/$id.tar" "$BACKUP_HOST:$remote_tar"
    ssh -o BatchMode=yes "$BACKUP_HOST" "
        pct push $BACKUP_CT $remote_tar $remote_tar && rm -f $remote_tar &&
        pct exec $BACKUP_CT -- sh -c '
            mkdir -p $BACKUP_ROOT && cd $BACKUP_ROOT &&
            tar --skip-old-files -xf $remote_tar && rm -f $remote_tar &&
            cd $id && sha256sum --quiet -c *.sha256 && echo \"$id: на сервере, суммы сходятся\"
        '
    "
done

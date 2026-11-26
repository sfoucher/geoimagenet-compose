#!/bin/bash
# Run on the administrator's workstation, as a normal user: ask the VM for a fresh dump, pull the dumps and
# the GeoServer configuration over SSH, and store them encrypted (rclone crypt) in $DEST/<date>/.
# Nothing else is pulled: never /nas, never env.local. The VM holds no cloud credential, so a
# compromised VM cannot delete the backups. Test mode: GIN_BACKUP_HOST=local (same host, no ssh).
set -euo pipefail
umask 077

H=${GIN_BACKUP_HOST:?set GIN_BACKUP_HOST=user@host}
REMOTE_COMPOSE=${REMOTE_COMPOSE:-geoimagenet/geoimagenet-compose}   # relative to the VM user's home
DEST=${DEST:-$HOME/geoimagenet-backups}                              # directory under the crypt remote
RCLONE_CONFIG_FILE=${RCLONE_CONFIG_FILE:-$HOME/.config/geoimagenet/rclone.conf}   # mode 600
REMOTE=${REMOTE:-localcrypt:}
KEEP_DAYS=${KEEP_DAYS:-60}
RCLONE_IMAGE=${RCLONE_IMAGE:-rclone/rclone:1.68.2@sha256:74c51b8817e5431bd6d7ed27cb2a50d8ee78d77f6807b72a41ef6f898845942b}
BACKUP_DIR=/data/postgis_backups; GS_DIR=/data/geoserver/data_dir; GSDS_DIR=/data/geoserver_datastore/data_dir

if [ "$H" = local ]; then   # tiny test mode
  run() { bash -c "$1"; }; SRC=""; RSH=(); SUDO=""; COMPOSE=$(cd "$(dirname "$0")/.." && pwd)
else
  run() { ssh "$H" "$1"; }; SRC="$H:"; RSH=(--rsync-path="sudo rsync"); SUDO="sudo "; COMPOSE="\$HOME/$REMOTE_COMPOSE"
fi
START=$SECONDS
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
mkdir "$S/dumps"

run "$SUDO$COMPOSE/scripts/offsite-backup.sh --dump-only"   # fresh dump + checks; non-zero stops here

for db in gis magpie twitcher; do
  f=$(run "$SUDO find $BACKUP_DIR -name 'geoimagenet_$db.*.dmp' -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-")
  [ -n "$f" ] || { echo "ERROR: no dump for $db on the host" >&2; exit 1; }
  rsync -t "${RSH[@]}" "$SRC$f" "$S/dumps/"
done
# gwc/ is the tile cache (rebuildable) except its geowebcache.xml; logs/ is noise.
for pair in "geoserver:$GS_DIR" "geoserver-datastore:$GSDS_DIR"; do
  rsync -rt "${RSH[@]}" --include=/gwc/ --include=/gwc/geowebcache.xml --exclude='/gwc/*' --exclude=/logs/ "$SRC${pair#*:}/" "$S/${pair%%:*}/"
done

D=$(date +%F)
rc() { docker run --rm --user "$(id -u):$(id -g)" -v "$RCLONE_CONFIG_FILE":/config/rclone/rconf/rclone.conf:ro \
  -e RCLONE_CONFIG=/config/rclone/rconf/rclone.conf -v "$DEST":"$DEST" -v "$S":/stage:ro "$RCLONE_IMAGE" "$@"; }
mkdir -p "$DEST"
rc copy -v /stage "${REMOTE}$D"

# Retention by folder name (file times are the source's, not the pull date). Local, so DELETE is fine.
cutoff=$(date -d "-$KEEP_DAYS days" +%F)
for d in $(rc lsf --dirs-only "$REMOTE"); do
  if [[ "$d" < "$cutoff/" ]]; then rc purge "${REMOTE}$d"; fi
done

echo "Pulled into ${REMOTE}$D (encrypted, under $DEST): $(find "$S" -type f | wc -l) files, $(du -sh "$S" | cut -f1) in clear; $((SECONDS - START)) s"

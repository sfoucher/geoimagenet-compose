#!/bin/bash
# Run on the administrator's workstation, as a normal user: ask the VM for a fresh dump, pull the dumps and
# the GeoServer configuration over SSH, and store them encrypted (rclone crypt) in $DEST/<date>/.
# Nothing else is pulled: never /nas, never env.local. The VM holds no cloud credential, so a
# compromised VM cannot delete the backups. Test mode: GIN_BACKUP_HOST=local (same host, no ssh).
# rsync exit 24 (files vanished while GeoServer runs) is not tolerated: the script aborts, which is safe.
set -euo pipefail
umask 077

H=${GIN_BACKUP_HOST:?set GIN_BACKUP_HOST=user@host}
REMOTE_COMPOSE=${REMOTE_COMPOSE:-geoimagenet/geoimagenet-compose}   # relative to the VM user's home
DEST=${DEST:-$HOME/geoimagenet-backups}                              # directory under the crypt remote
RCLONE_CONFIG_FILE=${RCLONE_CONFIG_FILE:-$HOME/.config/geoimagenet/rclone.conf}   # mode 600
REMOTE=${REMOTE:-localcrypt:}
KEEP_DAYS=${KEEP_DAYS:-60}
[[ "$KEEP_DAYS" =~ ^[1-9][0-9]*$ ]] || { echo "KEEP_DAYS must be a positive integer" >&2; exit 1; }
RCLONE_IMAGE=${RCLONE_IMAGE:-rclone/rclone:1.68.2@sha256:74c51b8817e5431bd6d7ed27cb2a50d8ee78d77f6807b72a41ef6f898845942b}
BACKUP_DIR=/data/postgis_backups; GS_DIR=/data/geoserver/data_dir; GSDS_DIR=/data/geoserver_datastore/data_dir

if [ "$H" = local ]; then   # tiny test mode
  run() { bash -c "$1"; }; SRC=""; RSH=(); SUDO=""; COMPOSE=$(cd "$(dirname "$0")/.." && pwd)
else
  run() { ssh -o BatchMode=yes -- "$H" "$1"; }; SRC="$H:"; RSH=(--rsync-path="sudo rsync"); SUDO="sudo "; COMPOSE="\$HOME/$REMOTE_COMPOSE"
fi
START=$SECONDS
[ -f "$RCLONE_CONFIG_FILE" ] || { echo "missing $RCLONE_CONFIG_FILE" >&2; exit 1; }
[ -d "$DEST" ] || { echo "missing $DEST" >&2; exit 1; }
S=$(mktemp -d); trap 'rm -rf "$S"' EXIT
mkdir "$S/dumps"
# --read-only: nothing can be written outside the mounts.
rc() { docker run --rm --read-only --tmpfs /tmp --user "$(id -u):$(id -g)" -v "$RCLONE_CONFIG_FILE":/config/rclone/rconf/rclone.conf:ro \
  -e RCLONE_CONFIG=/config/rclone/rconf/rclone.conf -v "$DEST":"$DEST" -v "$S":/stage:ro "$RCLONE_IMAGE" "$@"; }
dirs() { rc lsf --dirs-only "$REMOTE" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}/$' | sort || true; }

rc lsf "$REMOTE" >/dev/null || { echo "ERROR: cannot read $REMOTE (broken rclone config?)" >&2; exit 1; }
D=$(date +%F)
newest=$(dirs | tail -1)
if [ -n "$newest" ] && [[ "$D/" < "$newest" ]]; then echo "ERROR: today ($D) is before the newest backup folder $newest: wrong clock?" >&2; exit 1; fi

code=0; out=$(run "$SUDO$COMPOSE/scripts/offsite-backup.sh --dump-only") || code=$?   # fresh dump + checks
echo "$out"
if [ "$code" = 3 ]; then echo "ERROR: the VM skipped the dump (platform down or a backup already running): nothing pulled" >&2; exit 1; fi
[ "$code" = 0 ] || { echo "ERROR: dump failed on the VM (exit $code)" >&2; exit 1; }

for db in gis magpie twitcher; do
  f=$(printf '%s\n' "$out" | grep -E "/geoimagenet_$db\.[^/]*\.dmp$" | sort | tail -1 || true)
  [ -n "$f" ] || { echo "ERROR: no new dump for $db listed by the VM" >&2; exit 1; }
  rsync -t "${RSH[@]}" "$SRC$f" "$S/dumps/"
done
# gwc/ is the tile cache (rebuildable) except its geowebcache.xml; logs/ is noise.
for pair in "geoserver:$GS_DIR" "geoserver-datastore:$GSDS_DIR"; do
  rsync -rt "${RSH[@]}" --include=/gwc/ --include=/gwc/geowebcache.xml --exclude='/gwc/*' --exclude=/logs/ "$SRC${pair#*:}/" "$S/${pair%%:*}/"
done

mkdir -p "$DEST"
rc copy -v /stage "${REMOTE}$D"
[ -n "$(rc lsf "${REMOTE}$D/" | head -1)" ] || { echo "ERROR: ${REMOTE}$D is empty after the copy" >&2; exit 1; }

# Retention by folder name (file times are the source's, not the pull date). Local, so DELETE is fine.
# Only date-named folders, and the newest 3 are always kept.
cutoff=$(date -d "-$KEEP_DAYS days" +%F)
all=$(dirs); keep=$(printf '%s\n' "$all" | tail -3)
while read -r d; do
  [ -n "$d" ] || continue
  if [[ "$d" < "$cutoff/" ]] && ! printf '%s\n' "$keep" | grep -qx "$d"; then rc purge "${REMOTE}$d"; fi
done <<< "$all"

echo "Pulled into ${REMOTE}$D (encrypted, under $DEST): $(find "$S" -type f | wc -l) files, $(du -sh "$S" | cut -f1) in clear; $((SECONDS - START)) s"

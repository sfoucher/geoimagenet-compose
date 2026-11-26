#!/bin/bash
# Fresh dump, then (optionally) copy dumps + GeoServer configuration to an encrypted rclone remote (Swift).
# Never touches /nas or env.local. Run as root from anywhere. See README "Backups and restore".
# --dump-only (or DUMP_ONLY=1): stop after the dump and its checks and list the new dumps. This is the
# mode used by scripts/pull-backup.sh. The rclone/Swift part is currently unused: Arbutus' Ceph RGW
# answers 401 to every application credential restricted by access rules (see README).
set -euo pipefail
[ "${1:-}" = --dump-only ] && DUMP_ONLY=1
DUMP_ONLY=${DUMP_ONLY:-0}

RCLONE_CONFIG_FILE=${RCLONE_CONFIG_FILE:-/etc/geoimagenet/rclone.conf}
REMOTE=${REMOTE:-swiftcrypt:}                  # crypt remote (see scripts/rclone.conf.example)
DB_CONTAINER=${DB_CONTAINER:-postgis_backups}
BACKUP_DIR=${BACKUP_DIR:-/data/postgis_backups}
GS_DIR=${GS_DIR:-/data/geoserver/data_dir}
GSDS_DIR=${GSDS_DIR:-/data/geoserver_datastore/data_dir}
KEEP_LOCAL_DAYS=${KEEP_LOCAL_DAYS:-30}
LOCK_FILE=${LOCK_FILE:-/run/lock/geoimagenet-backup.lock}
PG_CONTAINER=${PG_CONTAINER:-postgis}
WAIT_SECONDS=${WAIT_SECONDS:-300}
RCLONE_IMAGE=${RCLONE_IMAGE:-rclone/rclone:1.68.2@sha256:74c51b8817e5431bd6d7ed27cb2a50d8ee78d77f6807b72a41ef6f898845942b}
RCLONE_DOCKER_ARGS=${RCLONE_DOCKER_ARGS:-}      # extra docker args, e.g. a -v for a local test backend, or -e RCLONE_DRY_RUN=true for a first dry run
EXPIRE=5184000                                   # Swift X-Delete-After: 60 days

# Sources are mounted read-only; the config too.
# shellcheck disable=SC2086
rc() { docker run --rm -i -v "$RCLONE_CONFIG_FILE":/config/rclone/rconf/rclone.conf:ro -e RCLONE_CONFIG=/config/rclone/rconf/rclone.conf \
  -v "$BACKUP_DIR":/src/dumps:ro -v "$GS_DIR":/src/gs:ro -v "$GSDS_DIR":/src/gsds:ro $RCLONE_DOCKER_ARGS "$RCLONE_IMAGE" "$@"; }
newest() { find "$BACKUP_DIR" -name "geoimagenet_$1.*.dmp" -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-; }
size_of() { if [ -n "$1" ]; then stat -c %s "$1"; else echo 0; fi; }

exec 9>"$LOCK_FILE"
flock -n 9 || { echo "Backup already running; nothing to do."; exit 0; }

if [ "$(docker inspect -f '{{.State.Running}}' "$DB_CONTAINER" 2>/dev/null || true)" != true ]; then
  echo "$DB_CONTAINER is not running (platform down): nothing changed since the last run, skipping."; exit 0
fi
wait_for() {  # wait_for "<description>" <command...>: bounded wait
  local what=$1; shift; local t=$SECONDS
  until "$@"; do [ $((SECONDS - t)) -lt "$WAIT_SECONDS" ] || { echo "ERROR: timeout waiting for $what" >&2; exit 1; }; sleep 5; done
}
wait_for "$PG_CONTAINER healthy" bash -c "[ \"\$(docker inspect -f '{{.State.Health.Status}}' $PG_CONTAINER)\" = healthy ]"
wait_for "a running pg_dump to end" bash -c "! docker exec $DB_CONTAINER pgrep pg_dump >/dev/null"

DBS="gis magpie twitcher"
declare -A prev
for db in $DBS; do prev[$db]=$(size_of "$(newest $db)"); done

MARK=$(mktemp); trap 'rm -f "$MARK"' EXIT
docker exec "$DB_CONTAINER" /backups.sh   # fresh dump: the VM is often off at the scheduled time

# backups.sh does not propagate pg_dump errors: require a dump newer than the marker, not empty, not shrunk.
for db in $DBS; do
  f=$(find "$BACKUP_DIR" -name "geoimagenet_$db.*.dmp" -newer "$MARK" | head -1)
  [ -n "$f" ] || { echo "ERROR: no new dump for $db" >&2; exit 1; }
  size=$(stat -c %s "$f")
  if [ "$size" -eq 0 ] || [ "$size" -lt $((prev[$db] / 2)) ]; then
    mv "$f" "$f.rejected"   # excluded from newest, upload and retention
    echo "ERROR: dump of $db is $size bytes (previous ${prev[$db]}); renamed to $(basename "$f").rejected, nothing uploaded" >&2; exit 1
  fi
done

if [ "$DUMP_ONLY" = 1 ]; then
  echo "New dumps:"; find "$BACKUP_DIR" -name 'geoimagenet_*.dmp' -newer "$MARK" -print; exit 0
fi

D=$(date +%F)
UP=(--header-upload "X-Delete-After: $EXPIRE")
# copy, not sync: no DELETE right needed. Filters are first-match: the + must precede the - .
F=(--filter '+ gwc/geowebcache.xml' --filter '- gwc/**' --filter '- logs/**')
rc copy -v "${UP[@]}" --max-age 2d --include '*.dmp' /src/dumps "${REMOTE}postgis"   # never the *.dmp.rejected
rc copy -v "${UP[@]}" "${F[@]}" /src/gs   "${REMOTE}geoserver/$D"
rc copy -v "${UP[@]}" "${F[@]}" /src/gsds "${REMOTE}geoserver-datastore/$D"

# Local retention: kartoza/pg-backup:9.6 has no REMOVE_BEFORE (its backups.sh never deletes).
case "$RCLONE_DOCKER_ARGS" in *RCLONE_DRY_RUN*) echo "Dry run: local retention skipped." ;;
  *) find "$BACKUP_DIR" -name '*.dmp' -mtime +"$KEEP_LOCAL_DAYS" -delete ;; esac
echo "Off-site backup $D done."

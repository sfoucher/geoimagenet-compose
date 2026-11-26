#!/bin/bash
# Restore drill: fetch the newest dumps, restore them into a throwaway PostGIS, assert, clean up.
# Usage: scripts/restore-test.sh [-d LOCAL_DUMP_DIR] [-n EXPECTED_ANNOTATIONS] [-u MAGPIE_ADMIN_USER]
# The twitcher database is empty in practice (no tables), so only its restore status is checked.
# Without -d, the newest dated folder of the crypt remote made by pull-backup.sh is used (REMOTE, DEST, RCLONE_CONFIG_FILE).
# Never run it against the production data dir: it only uses a temp dir and a container without network.
set -euo pipefail
cd "$(dirname "$0")/.."

RCLONE_CONFIG_FILE=${RCLONE_CONFIG_FILE:-$HOME/.config/geoimagenet/rclone.conf}
REMOTE=${REMOTE:-localcrypt:}
DEST=${DEST:-$HOME/geoimagenet-backups}
RCLONE_IMAGE=${RCLONE_IMAGE:-rclone/rclone:1.68.2@sha256:74c51b8817e5431bd6d7ed27cb2a50d8ee78d77f6807b72a41ef6f898845942b}
PG_IMAGE=${PG_IMAGE:-$(sed -n 's/^ *image: *\(kartoza\/postgis:[^ ]*\).*/\1/p' docker-compose.yml | head -1)}
LOCAL_DIR=""; EXPECT=""; ADMIN=${MAGPIE_ADMIN_USER:-}
while getopts d:n:u: o; do case $o in d) LOCAL_DIR=$OPTARG;; n) EXPECT=$OPTARG;; u) ADMIN=$OPTARG;; *) exit 2;; esac; done
if [ -z "$ADMIN" ] && [ -f env.local ]; then ADMIN=$(sed -n 's/^ *\(export \)\?MAGPIE_ADMIN_USER=//p' env.local | tail -1 | tr -d "\"'"); fi
[ -n "$ADMIN" ] || { echo "Give the Magpie admin user name with -u" >&2; exit 2; }

START=$SECONDS
T=$(mktemp -d); NAME=restore-test-$$
cleanup() {
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  # data dir is owned by the container's postgres user: remove it from a container
  docker run --rm -v "$T":/t --entrypoint sh "$PG_IMAGE" -c 'rm -rf /t/*' >/dev/null 2>&1 || true
  rm -rf "$T" 2>/dev/null || true
}
trap 'rc=$?; [ $rc -eq 0 ] || tail -20 "$T/pg_restore.log" 2>/dev/null; cleanup' EXIT
trap 'exit 130' INT TERM
mkdir "$T/in" "$T/pgdata"

if [ -n "$LOCAL_DIR" ]; then cp -r "$LOCAL_DIR"/. "$T/in/"; else
  # DEST is mounted at the same path, so the crypt remote's path in the config is valid in the container
  [ -f "$RCLONE_CONFIG_FILE" ] || { echo "missing $RCLONE_CONFIG_FILE" >&2; exit 1; }
  [ -d "$DEST" ] || { echo "missing $DEST" >&2; exit 1; }
  rc() { docker run --rm --read-only --tmpfs /tmp --user "$(id -u):$(id -g)" -v "$RCLONE_CONFIG_FILE":/config/rclone/rconf/rclone.conf:ro \
    -e RCLONE_CONFIG=/config/rclone/rconf/rclone.conf -v "$DEST":"$DEST" -v "$T/in":/in "$RCLONE_IMAGE" "$@"; }
  LAST=$(rc lsf --dirs-only "$REMOTE" | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}/$' | sort | tail -1)
  [ -n "$LAST" ] || { echo "FAIL: no backup folder in $REMOTE" >&2; exit 1; }
  echo "Using backup folder $LAST"
  rc copy "${REMOTE}${LAST}dumps" /in
fi

PW=$(openssl rand -hex 16)   # throwaway, never printed
docker run -d --name "$NAME" --network none -e POSTGRES_USER=restore -e POSTGRES_PASS="$PW" -e POSTGRES_DB=gis \
  -v "$T/pgdata":/var/lib/postgresql "$PG_IMAGE" >/dev/null
psql_() { docker exec -e PGPASSWORD="$PW" "$NAME" psql -h localhost -U restore -Atq "$@"; }
for _ in $(seq 60); do psql_ -d gis -c 'select 1' >/dev/null 2>&1 && break; sleep 2; done   # a real login, not pg_isready
psql_ -d gis -c 'select 1' >/dev/null
for db in magpie twitcher; do psql_ -d gis -c "create database $db"; done

for db in gis magpie twitcher; do
  f=$(find "$T/in" -name "geoimagenet_$db.*.dmp" -printf '%T@ %p\n' | sort -n | tail -1 | cut -d' ' -f2-)
  [ -n "$f" ] || { echo "FAIL: no dump for $db" >&2; exit 1; }
  echo "Restoring $db from $(basename "$f")"
  # pg_restore reports harmless errors (extension already exists); the assertions decide.
  docker exec -i -e PGPASSWORD="$PW" "$NAME" pg_restore -h localhost -U restore -d "$db" < "$f" 2>>"$T/pg_restore.log" || { echo "  (pg_restore reported warnings)"; [ "$db" != twitcher ] || { echo "FAIL: twitcher restore failed" >&2; exit 1; }; }
  [ -n "$(find "$f" -mtime -2)" ] || echo "WARNING: $(basename "$f") is older than 2 days"
done

N=$(psql_ -d gis -c 'select count(*) from annotation')
if [ -n "$EXPECT" ]; then [ "$N" = "$EXPECT" ] || { echo "FAIL: annotation count $N, expected $EXPECT" >&2; exit 1; }
else [ "$N" -gt 0 ] || { echo "FAIL: annotation table empty" >&2; exit 1; }; fi
A=$(psql_ -d magpie -c "select count(*) from users where user_name='$ADMIN'")
[ "$A" -ge 1 ] || { echo "FAIL: magpie has no user '$ADMIN'" >&2; exit 1; }
echo "PASS: annotations=$N, magpie user '$ADMIN' present, elapsed $((SECONDS - START)) s"

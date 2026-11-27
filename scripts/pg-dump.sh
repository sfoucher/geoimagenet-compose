#!/bin/bash
# Dump gis, magpie and twitcher with pg_dump run inside the postgis container (client and server
# versions always match). Layout and names are those of the old kartoza/pg-backup container:
#   $BACKUP_DIR/<year>/<Month>/geoimagenet_<db>.<dd-Month-YYYY>.dmp
# Each dump is written to .tmp, checked, then renamed: a failed run never leaves a bad .dmp.
# The newest 14 dumps of each database are kept (a long off period never leaves a single dump).
# /data/postgis_backups is root-owned: run it as `sudo ./scripts/pg-dump.sh` (env.local must be readable by root). Roles are not dumped: the container environment
# recreates the role on an empty cluster.
#   env: BACKUP_DIR (default /data/postgis_backups), PG_CONTAINER (default postgis),
#        PG_USER / PG_PASSWORD (default POSTGIS_USER / POSTGIS_PASSWORD from env.local)
# The first run on PostgreSQL 17 must come after the last 9.6 dumps were copied to
# /data/postgis_backups_pre-pg17/ (outside the retention cleanup): see README, "Cut-over".
set -euo pipefail
umask 077
if [ -z "${PG_PASSWORD:-}" ]; then set -a; . "$(dirname "$0")/../env.local"; set +a; fi
U=${PG_USER:-$POSTGIS_USER}; P=${PG_PASSWORD:-$POSTGIS_PASSWORD}; C=${PG_CONTAINER:-postgis}
B=${BACKUP_DIR:-/data/postgis_backups}
export LC_ALL=C   # English month names, as the old kartoza dumps
D=$B/$(date +%Y)/$(date +%B); mkdir -p "$D"
trap 'rm -f "${f:-}.tmp"' EXIT
for db in gis magpie twitcher; do
  f="$D/geoimagenet_$db.$(date +%d-%B-%Y).dmp"
  prev=$(ls -t "$B"/*/*/geoimagenet_$db.*.dmp 2>/dev/null | head -1 || true)
  PGPASSWORD="$P" docker exec -e PGPASSWORD "$C" pg_dump -h localhost -U "$U" -Fc "$db" > "$f.tmp"
  [ -s "$f.tmp" ] || { echo "empty dump: $db" >&2; exit 1; }
  if [ -n "$prev" ] && [ "$(stat -c%s "$f.tmp")" -lt $(( $(stat -c%s "$prev") / 2 )) ]; then
    echo "dump of $db is less than half of $prev: not kept" >&2; exit 1
  fi
  mv "$f.tmp" "$f"; echo "$f ($(stat -c%s "$f") bytes)"
  ls -t "$B"/*/*/geoimagenet_$db.*.dmp | tail -n +15 | xargs -r rm --
done

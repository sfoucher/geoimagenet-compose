#!/bin/bash
# Restore the newest dump of each database from a dump folder into the (empty) databases created by
# config/postgres/docker-entrypoint-initdb.d/10-databases.sh. Runs PostgreSQL's pg_restore inside the
# postgis container, as the superuser. Prints the errors and fails on any that is not in the allow-list.
#   usage: pg-restore.sh <dump-dir> [db...]       (default: gis magpie twitcher)
#   example: ./scripts/pg-restore.sh /data/postgis_backups/2026/November
#   env: PG_CONTAINER (default postgis), PG_USER / PG_PASSWORD (default POSTGIS_USER / POSTGIS_PASSWORD from env.local)
# A 9.6 dump restores into 17, never the reverse.
set -euo pipefail
dir=${1:?usage: pg-restore.sh <dump-dir> [db...]}; shift
dbs=${*:-gis magpie twitcher}
if [ -z "${PG_PASSWORD:-}" ]; then set -a; . "$(dirname "$0")/../env.local"; set +a; fi
U=${PG_USER:-$POSTGIS_USER}; P=${PG_PASSWORD:-$POSTGIS_PASSWORD}; C=${PG_CONTAINER:-postgis}
# Expected on a 9.6 / PostGIS 2.4 dump, nothing else:
# - the schema public and the extensions postgis and plpgsql already exist in the new cluster;
# - spatial_ref_sys keeps the rows of PostGIS 3.5 (a COPY of old rows would fail on duplicate keys);
# - the 9.6 dumps carry ~12 legacy PostGIS aliases created outside the extension (asbinary, astext,
#   setsrid, ...), which point at the 2.4 library. They are PostGIS 1.x names that nothing here calls
#   (the app and GeoServer use ST_*); the eight written in C fail, the rest are restored. Any other
#   function failing that way is not allowed.
LEGACY='asbinary|astext|estimated_extent|geomfromtext|ndims|setsrid|srid|st_asbinary|st_astext'
ALLOW='schema "public" already exists|extension "(postgis|plpgsql)" already exists|spatial_ref_sys.*duplicate key value|duplicate key value.*spatial_ref_sys|could not access file "\$libdir/postgis-2\.4"'
fail=0
for db in $dbs; do
  f=$(ls -t "$dir"/geoimagenet_"$db".*.dmp 2>/dev/null | head -1 || true)
  [ -n "$f" ] || { echo "no dump of $db in $dir" >&2; exit 1; }
  echo "== $db <- $f"
  t=$(date +%s); log=$(mktemp); rc=0
  docker exec -i -e PGPASSWORD="$P" "$C" pg_restore -h localhost -U "$U" -d "$db" --no-owner --role="$U" < "$f" 2> "$log" || rc=$?
  errs=$(grep -E '^pg_restore: error|ERROR:' "$log" || true)
  bad=$(printf '%s\n' "$errs" | grep -v '^$' | grep -Ev "$ALLOW" || true)
  # a "$libdir" failure is only allowed for the legacy functions
  bad+=$'\n'$(grep '^Command was: CREATE FUNCTION' "$log" | grep -Ev "CREATE FUNCTION public\.($LEGACY)\(" || true)
  bad=$(printf '%s\n' "$bad" | grep -v '^$' || true)
  echo "   $(( $(date +%s) - t )) s, exit $rc, $(printf '%s\n' "$errs" | grep -vc '^$' || true) error line(s), $(printf '%s\n' "$bad" | grep -vc '^$' || true) not allowed"
  if [ -n "$bad" ]; then printf '%s\n' "$bad" >&2; fail=1
  elif [ "$rc" -ne 0 ] && ! grep -q 'errors ignored on restore' "$log"; then cat "$log" >&2; fail=1; fi
  rm -f "$log"
done
[ "$fail" -eq 0 ] || { echo "RESTORE FAILED" >&2; exit 1; }
echo "restore OK: $dbs"

#!/bin/bash
# Read-only fingerprint of gis, magpie and twitcher: extensions, alembic versions, row counts,
# sequence values, and md5 checksums of the tables that matter. Prints hashes and counts only,
# never data. Run it before and after a move and diff the two outputs:
#   ./scripts/db-fingerprint.sh > old.txt ; ... ; ./scripts/db-fingerprint.sh | diff old.txt - && echo IDENTICAL
# Works against kartoza 9.6 and postgis 17: it runs psql inside the container.
#   usage: db-fingerprint.sh [container]          (default: postgis)
#   env:   PG_USER, PG_PASSWORD (default: POSTGIS_USER/POSTGIS_PASSWORD from env.local), PG_HOST (default localhost)
# Not hashed on purpose: whole rows as text (float output, collation and timezone differ across versions)
# and spatial_ref_sys / extension versions (differ by design between PostGIS 2.4 and 3.5).
set -euo pipefail
C=${1:-postgis}
if [ -z "${PG_PASSWORD:-}" ]; then set -a; . "$(dirname "$0")/../env.local"; set +a; fi
U=${PG_USER:-$POSTGIS_USER}; P=${PG_PASSWORD:-$POSTGIS_PASSWORD}; H=${PG_HOST:-localhost}
psql_() { docker exec -i -e PGPASSWORD="$P" -e PGOPTIONS='-c TimeZone=UTC' "$C" psql -h "$H" -U "$U" -d "$1" -X -A -t -q -v ON_ERROR_STOP=1; }

# db|table|row expression (key columns first; geometry as hex EWKB)
SUMS='gis|annotation|concat_ws(chr(124),id,annotator_id,taxonomy_class_id,status,review_requested,name,image_id,updated_at,encode(ST_AsEWKB(geometry),chr(104)||chr(101)||chr(120)))
gis|image|concat_ws(chr(124),id,sensor_name,bands,bits,filename,extension,layer_name,encode(ST_AsEWKB(trace),chr(104)||chr(101)||chr(120)),encode(ST_AsEWKB(trace_simplified),chr(104)||chr(101)||chr(120)))
gis|taxonomy|concat_ws(chr(124),id,name_fr,name_en,version)
gis|taxonomy_class|concat_ws(chr(124),id,taxonomy_id,parent_id,name_fr,name_en,code)
gis|person|concat_ws(chr(124),id,username,email)
magpie|users|concat_ws(chr(124),id,user_name,user_password,email,status)
magpie|groups|concat_ws(chr(124),id,group_name,description)
magpie|users_groups|concat_ws(chr(124),group_id,user_id)
magpie|resources|concat_ws(chr(124),resource_id,resource_name,resource_type,parent_id,owner_user_id,owner_group_id,root_service_id)
magpie|services|concat_ws(chr(124),resource_id,type,url)
magpie|users_permissions|concat_ws(chr(124),user_id,perm_name)
magpie|groups_permissions|concat_ws(chr(124),group_id,perm_name)
magpie|users_resources_permissions|concat_ws(chr(124),resource_id,user_id,perm_name)
magpie|groups_resources_permissions|concat_ws(chr(124),resource_id,group_id,perm_name)'

for db in gis magpie twitcher; do
  echo "== $db"
  psql_ $db <<'SQL'
select 'ext '||extname from pg_extension order by 1;
select 'alembic '||(xpath('/row/v/text()', query_to_xml('select version_num as v from public.alembic_version', false, true, '')))[1]::text where to_regclass('public.alembic_version') is not null;
select 'rows '||n.nspname||'.'||c.relname||' '||(xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', n.nspname, c.relname), false, true, '')))[1]::text
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where c.relkind in ('r','p') and n.nspname not in ('pg_catalog','information_schema') and c.relname<>'spatial_ref_sys'
  order by n.nspname, c.relname;
select 'seq '||n.nspname||'.'||c.relname||' '||(xpath('/row/v/text()', query_to_xml(format('select last_value as v from %I.%I', n.nspname, c.relname), false, true, '')))[1]::text
  from pg_class c join pg_namespace n on n.oid=c.relnamespace
  where c.relkind='S' and n.nspname not in ('pg_catalog','information_schema') order by 1;
SQL
  echo "$SUMS" | while IFS='|' read -r d t e; do
    [ "$d" = "$db" ] || continue
    # tables absent from a database (an older schema) are skipped, not an error
    printf 'md5 %s ' "$t"
    psql_ $db <<SQL
select coalesce((select md5(coalesce(string_agg(x, ',' order by x collate "C"), '')) from (select $e as x from public.$t) s), 'absent') where to_regclass('public.$t') is not null;
SQL
  done
done

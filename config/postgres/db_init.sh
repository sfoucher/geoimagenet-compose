#!/bin/bash
# Create the magpie and twitcher databases if missing. Only "gis" is created by the
# PostGIS image; Magpie and Twitcher need their own. Idempotent: safe on every "up".
set -euo pipefail
for db in magpie twitcher; do
  if [ "$(psql -h postgis -d "$PGDATABASE" -Atc "select 1 from pg_database where datname='$db'")" != 1 ]; then
    psql -h postgis -d "$PGDATABASE" -c "create database $db owner \"$PGUSER\""
  else
    echo "database $db exists"
  fi
done

#!/bin/bash
# Runs once, as the superuser, on an empty data directory (the image's init hook).
# gis, magpie and twitcher come from template0: no PostGIS objects unless asked for, so the
# schema of gis matches what the migrations and a restored dump expect. PostGIS goes in gis only.
# The database name "gis" is POSTGIS_DB in env.local.example: keep them equal.
set -euo pipefail
for db in gis magpie twitcher; do
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres \
    -c "CREATE DATABASE $db TEMPLATE template0 OWNER \"$POSTGRES_USER\""
done
psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d gis -c "CREATE EXTENSION postgis"

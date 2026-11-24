# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Deployment orchestration only for the GeoImageNet platform (CRIM). There is no application source here, no build, and no tests. The app code lives in separate repos (`crim-ca/geoimagenet-api`, `-frontend`, `-ml`, `-graphql`) and is consumed as pinned Docker images. See `DEPLOYMENT_PLAN.md` for the full analysis, the deployment plan, the modernization roadmap and the cloud hosting options.

## Source repos for the custom images

| Repo | Tag | Image |
|---|---|---|
| `crim-ca/geoimagenet-api` | `1.4.2` | `api` (also used by `migrations` and `geoserver_setup`) |
| `crim-ca/geoimagenet-frontend` | `1.8.3` | `frontend` |
| `crim-ca/geoimagenet-ml` | `2.2.1` | `ml` |
| `crim-ca/geoimagenet-graphql` | `0.2.4` | `graphql` |

- The tags must match the image tags in `docker-compose.yml`. Bump both together.
- The `ml` build also installs `crim-ca/gin-model-repo@1.0.1` (from GitHub) and `thelper==0.6.2` (from PyPI). Neither needs cloning unless you modify it.
- No public source exists for `geoimagenet/geoserver:2.14.0`. Substitute `kartoza/geoserver:2.15.0` via the override file (no kartoza 2.14 tag exists).
- `crim-ca/geoimagenet` contains only example notebooks for model packaging; the platform doesn't need it.
- The source repos are cloned as siblings of this repo under `~/DEV/geoimagenet/`. A local `docker-compose.override.yml` can point `build: ../geoimagenet-<name>` at them, so `./geoimagenet-compose.sh build <service>` builds from source. Details are in `DEPLOYMENT_PLAN.md` §9.

## Commands

Always go through the wrapper, never call compose directly. Every service requires `USING_GEOIMAGENET_COMPOSE`, which only the wrapper exports.

```bash
./geoimagenet-compose.sh up -d                              # start everything (also restarts nginx after "up")
./geoimagenet-compose.sh logs -f <service>
./geoimagenet-compose.sh pull <service> [<service>...]      # never a bare "pull" (see the PostGIS gotcha below)
./geoimagenet-compose.sh run --rm migrations upgrade head   # init/upgrade the "gis" db (alembic)
./geoimagenet-compose.sh run --rm magpie gunicorn -b 0.0.0.0:2001 --paste config/magpie.ini --workers 1   # init magpie db; Ctrl-C after "Starting Magpie app..."
make VERSION=x.y.z bump                                     # bump2version: commits and tags
make VERSION=x.y.z dry bump                                 # preview only
```

First run needs `env.local` (copy `env.local.example`) and the bind-mount directories created on the host (`/nas`, `/data/...`; the exact `mkdir` is in README.md).

## How configuration works (read before editing config/)

- `geoimagenet-compose.sh` sources `env.local`, then runs `envsubst` on every **git-tracked** `*.template` file and writes the result next to it without the `.template` suffix (for example `magpie.ini.template` becomes `magpie.ini`). The generated files are gitignored.
  - Edit the `.template`, never the generated file; the generated file is overwritten on every wrapper call.
  - A new template must be `git add`ed before the wrapper will render it.
- `envsubst` only substitutes the variables listed in `VARS` inside `geoimagenet-compose.sh`. A variable that is not listed there stays as a literal `${...}` in the output. For example, `PHOENIX_PASSWORD` in `magpie.env.template` is not substituted today.
- Every variable in `VARS` must be non-empty, or the wrapper exits with status 1.
- Local overrides (ports, CORS, dev SSL settings, image swaps) belong in `docker-compose.override.yml`, which is gitignored. README.md has the local-dev override and the self-signed certificate steps.
- The version string lives in three places that are kept in sync by bump2version (`setup.cfg`): `docker-compose.yml` (`GEOIMAGENET_VERSION`), `canarie_api_config.py.template` and `doc.html.template`.

## Architecture (big picture)

- **Entry point:** `nginx` (the `pavics/canarieapi` image, which bundles nginx and the CANARIE monitoring app on :2000). Routing is in `config/nginx/conf.d/geoimagenet.conf.template`.
  - `/` serves the static frontend from the `dist` volume. The `frontend` container runs a webpack build into that volume at startup (2–3 minutes before the UI responds).
  - `/graphql` goes to `graphql:4000` directly, **not** through Twitcher.
  - `/magpie` goes to `magpie:2001`.
  - `/api`, `/ml` and `/geoserver` go to `twitcher:8001/ows/proxy/<name>`.
- **Auth:** Magpie stores users and permissions. Twitcher is the security proxy that asks Magpie (`MagpieAdapter`) before forwarding. A service only gets protected routing if it is registered in `config/magpie/providers.cfg`; permissions are in `permissions.cfg`.
- **Databases:**
  - One PostGIS container holds the `gis` db (api annotations, migrated by the `migrations` job), the `magpie` db and the `twitcher` db.
  - MongoDB stores ML job state only.
- **One-shot jobs:**
  - `migrations` runs alembic on the `gis` db.
  - `geoserver_setup` uses the api image to mirror layers from an upstream GeoServer (`GEOIMAGENET_API_GS_DATASTORE_URL`) into the local one, configured by `config/api/geoserver_config.yaml`.
- **Shared-path coupling:** `graphql` and `ml` must mount `ml_models` at the same `RAW_MODEL_STORAGE_PATH`. Changing it in only one of them breaks model upload.
- **Storage:** all named volumes are bind mounts to fixed host paths (`/nas` holds the imagery; `/data/...` holds the databases, ML files and backups). Compose fails at mount time if a directory is missing.

## Gotchas

- **PostGIS breaks after an unnecessary image pull** (`could not access file "$libdir/postgis-2.5"`). Pull only the images you are updating. The recovery procedure (wipe the data dir, re-init, `pg_restore` from `/data/postgis_backups`) is in README.md.
- **The wrapper calls the `docker compose` v2 plugin** (changed from the v1 `docker-compose` binary on branch `docs/deployment-plan`). Hosts with only v1 need the plugin installed.
- **The CRIM images (`docker-registry.crim.ca/...`) are only reachable on the CRIM network.** Elsewhere, build them from the GitHub repos at the pinned tags (see `DEPLOYMENT_PLAN.md` §5, Phase 1).
- **GeoServer is set to `-Xmx10G`.** Reduce it in the override file on hosts with less than about 24 GB of RAM. With the kartoza image, set `MAXIMUM_MEMORY` and replace `JAVA_OPTS`: its entrypoint appends its own heap flags, built from `MAXIMUM_MEMORY`, after `JAVA_OPTS`.
- **`docker-compose.override.yml.example`** is the working local override (source builds, kartoza GeoServer, 4 GB heap). Copy it to `docker-compose.override.yml`.
- **Secrets come only from `env.local`** (on branch `feature/annotation-only`). Generate each with `openssl rand -hex 32`; hex avoids escaping in the Twitcher database URL. The default passwords, the GitHub OAuth secret and the Slack webhook were removed from the tracked files, but they remain in Git history and in CRIM's public repository, so CRIM must revoke the OAuth secret and the webhook.
- **GeoServer's admin password is applied on first start only** (kartoza writes a lock file into the data dir). Changing `GEOIMAGENET_API_GS_MIRROR_PASSWORD` later needs the password changed in GeoServer too.

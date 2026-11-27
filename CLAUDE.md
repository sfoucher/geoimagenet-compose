# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Deployment orchestration only for the GeoImageNet platform (CRIM). There is no application source here, no build, and no tests. The app code lives in the forks `sfoucher/geoimagenet-api` and `-frontend` and is consumed as digest-pinned images from GHCR. Branch `feature/annotation-only` (the deployed one) keeps only annotation: the `ml`, `graphql` and `mongodb` services are removed. See `../DEPLOYMENT_PLAN.md` for the analysis and hosting options, and `../MODERNIZATION_STEP1..4.md` for the modernization plans and their progress notes.

## Deployments

- **Local WSL2 copy** (this checkout) and **one Arbutus VM** (`ubuntu@<vm>`, checkout at `~/geoimagenet/geoimagenet-compose`, server override). Both run the same commit; the VM is used on demand.
- The VM gets code as a Git bundle of this branch (no GitHub access needed there). Apply it with `git pull --ff-only` from the bundle, then the steps of the change's runbook.
- Rollback points on both hosts: tags `cut-0` (before PostgreSQL 17), `cut-1` (before GeoServer 3), `cut-2` (after). Kept until a few periods have passed: `/data/db_gis_data` and `/data/postgis_backups_pre-pg17` (9.6), the 2.15 dirs `/data/geoserver*/data_dir`, and the saved 2.15 GeoServer image (`geoserver-2.15-image.tar.gz`).

## Source repos for the custom images

| Repo | Tag | Image |
|---|---|---|
| `sfoucher/geoimagenet-api` (fork of `crim-ca/`), branch `fix/build-2026` | `1.4.2-gin.2` (GeoServer 3 support; upstream base 1.4.2) | `ghcr.io/sfoucher/geoimagenet-api`: `api` (also used by `migrations` and `geoserver_setup`) |
| `sfoucher/geoimagenet-frontend` (fork of `crim-ca/`), branch `fix/build-2026` | `1.8.3-gin.4` (static image, OSM default, Mapbox satellite, no Bing; gin.1 builds at start; upstream base 1.8.3) | `ghcr.io/sfoucher/geoimagenet-frontend`: `frontend_files`, copied into the `public` volume nginx serves |

- The tags must match the image tags in `docker-compose.yml`. Bump both together.
- `api` and `frontend` don't build from the tags any more: use branch `fix/build-2026` of the forks `sfoucher/geoimagenet-api` (dependencies pinned to 2020 releases, `geoserver_setup` fixes) and `sfoucher/geoimagenet-frontend` (ML pages hidden).
- `crim-ca/geoimagenet-ml` and `-graphql` are not used on `feature/annotation-only`.
- Both GeoServers are the official `docker.osgeo.org/geoserver:3.0.2` (index digest pinned in `docker-compose.yml` and the override examples); there is no custom GeoServer image any more.
- The source repos are cloned as siblings of this repo under `~/DEV/geoimagenet/`. For local builds, the override examples hold a commented block with `build: ../geoimagenet-<name>`; then `./geoimagenet-compose.sh build <service>` builds from source. Details are in `../DEPLOYMENT_PLAN.md` §9.

## Commands

Always go through the wrapper, never call compose directly. Every service requires `USING_GEOIMAGENET_COMPOSE`, which only the wrapper exports.

```bash
./geoimagenet-compose.sh up -d --wait                       # start everything, in health order (also restarts nginx after "up")
./geoimagenet-compose.sh logs -f <service>
./geoimagenet-compose.sh pull <service> [<service>...]      # never a bare "pull" (see the PostGIS gotcha below)
./geoimagenet-compose.sh run --rm migrations upgrade head   # init/upgrade the "gis" db (alembic); "up" also runs it
./geoimagenet-compose.sh run --rm geoserver_setup ...       # profile "setup": never started by a bare "up"
make VERSION=x.y.z bump                                     # bump2version: commits and tags
make VERSION=x.y.z dry bump                                 # preview only
```

First run: follow README.md (the verified operations guide: installation order, imagery loading, daily operation, users, backups). It needs `env.local` (copy `env.local.example`), the override (copy `docker-compose.override.yml.example`) and the bind-mount directories on the host.

## How configuration works (read before editing config/)

- `geoimagenet-compose.sh` sources `env.local`, then runs `envsubst` on every **git-tracked** `*.template` file and writes the result next to it without the `.template` suffix (for example `magpie.ini.template` becomes `magpie.ini`). The generated files are gitignored.
  - Edit the `.template`, never the generated file; the generated file is overwritten on every wrapper call.
  - A new template must be `git add`ed before the wrapper will render it.
- `envsubst` only substitutes the variables listed in `VARS` inside `geoimagenet-compose.sh`. A variable that is not listed there stays as a literal `${...}` in the output. Add any new template variable to `VARS`.
- Every variable in `VARS` must be non-empty, or the wrapper exits with status 1. An optional feature uses a sentinel instead of an empty value: `MAPBOX_TOKEN=none` hides the Mapbox layer.
- Local overrides (ports, CORS, dev SSL settings, image swaps) belong in `docker-compose.override.yml`, which is gitignored. README.md has the local-dev override and the self-signed certificate steps.
- The version string lives in two places that are kept in sync by bump2version (`setup.cfg`): `canarie_api_config.py.template` and `doc.html.template` (the `GEOIMAGENET_VERSION` line went with the `frontend` service). Both go when CANARIE is dropped (step 2, block N); versions will then be git tags only.

## Architecture (big picture)

- **Entry point:** `nginx` (the `pavics/canarieapi` image, which bundles nginx and the CANARIE monitoring app on :2000). Routing is in `config/nginx/conf.d/geoimagenet.conf.template`.
  - `/` serves the static frontend from the `public` volume, filled at each `up` by the one-shot `frontend_files` (image `ghcr.io/sfoucher/geoimagenet-frontend`, pinned by digest; nginx waits for it). Not an image mount: Docker 29 fails to mount an image referenced by digest ("file name too long"). `/config.js` is not in the image: nginx generates it (`return 200` in `geoimagenet.conf.template`, from `HOST_FQDN`, `CONTACT_EMAIL` and `MAPBOX_TOKEN`). Base maps: OSM (default) and Mapbox Satellite (only when `MAPBOX_TOKEN` is a real public `pk.` token, URL-restricted to the platform's addresses in the Mapbox account); Bing is gone. Local frontend dev: see the override examples.
  - `/graphql` and `/ml` are removed on `feature/annotation-only`. The `api` environment still defines `GRAPHQL_ENDPOINT`, `ML_ENDPOINT` and `GEOIMAGENET_API_BATCH_CREATION_URL`; nothing calls them.
  - `/magpie` goes to `magpie:2001`.
  - `/api` and `/geoserver` go to `twitcher:8001/ows/proxy/<name>`.
- **Auth:** Magpie stores users and permissions. Twitcher is the security proxy that asks Magpie (`MagpieAdapter`) before forwarding. A service only gets protected routing if it is registered in `config/magpie/providers.cfg`; permissions are in `permissions.cfg`.
- **Databases:**
  - One PostGIS container holds the `gis` db (api annotations, migrated by the `migrations` job), the `magpie` db and the `twitcher` db.
- **One-shot jobs:**
  - `migrations` runs alembic on the `gis` db.
  - `geoserver_setup` uses the api image to mirror layers from an upstream GeoServer (`GEOIMAGENET_API_GS_DATASTORE_URL`) into the local one, configured by `config/api/geoserver_config.yaml`.
- **Storage:** all named volumes are bind mounts to fixed host paths. Compose fails at mount time if a directory is missing (create it with `sudo install -d`).
  - `/nas/PLEIADES_RGBN_8/*.tif`: the imagery (COG with internal mask; 40 scenes on the VM, Sherbrooke only locally); `/nas/PLEIADES_CONTOURS/*_trace.*`: CRIM's original footprints (named `16bits`, matched to the 8-bit images by `geoserver_setup`); `/nas/originals/`: unpublished originals.
  - `/data/db_gis_17` (PostgreSQL 17), `/data/geoserver_3/data_dir` and `/data/geoserver_datastore_3/data_dir` (GeoServer 3), `/data/postgis_backups` (dumps).
  - The imagery is licensed (Airbus): never in git, an image, GHCR or public storage.

## Gotchas

- **PostGIS is `postgis/postgis:17-3.5`, pinned by digest** (it was kartoza 9.6, whose tag was re-pushed with a different build and broke with `could not access file "$libdir/postgis-2.5"`). Never replace the digest with a freshly resolved one; pull only the images you are updating. Env vars are the official image's: `POSTGRES_USER`, `POSTGRES_PASSWORD` (not `POSTGRES_PASS`), and `POSTGRES_DB=postgres` (harmless: the bind-mounted `initdb.d` replaces the image's own `10_postgis.sh`, which would otherwise create PostGIS extensions in `$POSTGRES_DB` and break the `fuzzystrmatch` migration). The wrapper refuses a `POSTGIS_DB` other than `gis`. User and password are applied once, on an empty data directory. Data is at `/data/db_gis_17`; the old `/data/db_gis_data` (9.6) is the rollback until the cut-over has proven itself.
- **Databases come from `config/postgres/docker-entrypoint-initdb.d/10-databases.sh`**, which runs once on an empty data directory: `gis`, `magpie`, `twitcher` from `template0`, PostGIS in `gis` only. `db_init` no longer exists. The `gis` name there must equal `POSTGIS_DB`.
- **Backups and restore are scripts, not a container:** `scripts/pg-dump.sh` (nothing runs it automatically: run it at the end of each period, `sudo` on the VM, or from a root cron line; keeps the newest 14 dumps per database; off-site backups were dropped by the administrator), `scripts/pg-restore.sh <dump-dir> [db...]` (superuser restore with an error allow-list; a 9.6 dump restores into 17, never the reverse) and `scripts/db-fingerprint.sh` (read-only before/after comparison). The 9.6-to-17 cut-over runbook and the `psql_gis` helper are in README.md (Backups and restore).
- **The wrapper calls the `docker compose` v2 plugin** (changed from the v1 `docker-compose` binary on branch `docs/deployment-plan`). Hosts with only v1 need the plugin installed.
- **`api` and `frontend` come from GHCR** (`ghcr.io/sfoucher/`), built by GitHub Actions in the forks when a `v*` tag is pushed (release routine in README.md, Versioning). A local `docker-compose.override.yml` can build them from the sibling repos instead (commented block in the override examples; it sets `image:` on `api`, `migrations` and `geoserver_setup`). Package visibility must be set to Public once in the GitHub UI.
- **GeoServer heap** is `EXTRA_JAVA_OPTS` (`-Xmx4G` platform in `docker-compose.yml`, `-Xmx2G` datastore in the override). It replaces the image's `-Xmx1g`, so keep `-Dorg.geotools.referencing.forceXY=true -Duser.timezone=GMT` in it. Reduce it on hosts with little RAM.
- **`docker-compose.override.yml.example`** is the working local override (GHCR images, the datastore GeoServer, GeoServer on port 8600, Magpie SSL verification off). Copy it to `docker-compose.override.yml`, and re-copy it after a change to the example (keep a `.bak`).
- **Secrets come only from `env.local`** (on branch `feature/annotation-only`). Generate each with `openssl rand -hex 32`; hex avoids escaping in the Twitcher database URL. The default passwords, the GitHub OAuth secret and the Slack webhook were removed from the tracked files, but they remain in Git history and in CRIM's public repository, so CRIM must revoke the OAuth secret and the webhook.
- **First initialization is one command** (`up -d --wait`). It used to have three traps, now handled in the compose file; don't undo them:
  - The PostGIS healthcheck does a real TCP login on `gis`: the image's init scripts run on a temporary server bound to the Unix socket only, so the check cannot pass before the databases exist.
  - `gis`, `magpie` and `twitcher` are created by the init script (see above), so `magpie` and `twitcher` need no manual step.
  - Concurrent Magpie workers corrupt its first database migration; `preload_app = true` in `magpie.ini.template` runs it once in the gunicorn master.
- **Stop the platform with `down`, not `stop`**: `magpie`, `twitcher` and `nginx` have `restart: always`, and the GeoServers `unless-stopped`, so they would come back alone at the next boot. `down` keeps all data (bind mounts and named volumes). After a reboot of an always-on host, run `up -d --wait`.
- **Servers use `docker-compose.override.server.yml.example`**: the local example publishes GeoServer on 8600, bypassing Twitcher, and disables Magpie SSL verification.
- **nginx keeps the IP it resolved at start** for `twitcher` and `magpie`. `depends_on: restart: true` restarts it on `compose restart <svc>` but **not** on `up --force-recreate <svc>` (tested), so the wrapper still restarts nginx after every `up`. Keep both.
- **Keep the Twitcher ACL cache disabled** (`cache.regions = acl` in `twitcher.ini.template`): incompatible with route-level permissions in Magpie 1.6.
- **Imagery path:** the platform's `geoserver` cascades WMS from a separate datastore GeoServer (`geoserver-datastore` locally, see the override example), which serves the GeoTIFFs from `/nas`. `geoserver_setup --setup-datastore` configures both. The datastore's tile cache needs `<fullWMS>true</fullWMS>` in `gwc/geowebcache.xml`. Add it **after** the first `geoserver_setup`: before that, the file has no `<layers/>` line and the README's `sed` changes nothing (it prints the match count; 1 means it worked).
- **Never use `_` in a GeoServer container name** others call over HTTP: Tomcat answers 400 to such Host headers.
- **GeoServer is the official image 3.0.2** (Java 21, Tomcat 11, pgJDBC 42.7 so SCRAM works, patched for CVE-2024-36401; the old derived `docker/geoserver/Dockerfile` is gone, don't bring it back). Data dir `/opt/geoserver_data`, bind-mounted from the NEW host dirs `/data/geoserver_3/data_dir` and `/data/geoserver_datastore_3/data_dir` (the 2.15 dirs are the rollback; the compose volume is `geoserver3_data` so an old volume definition can't clash). The image has no `web.xml` mount, CORS or `geoserver.env` any more. The `annotations` style is created from `styles/annotations.sld` by `geoserver_setup` (needs the api image with the GeoServer 3 fixes: older ones fail with `No endpoint POST /geoserver/rest/namespaces/.`).
- **The official image rewrites the admin user and password at every start** (`GEOSERVER_ADMIN_USER`, `GEOSERVER_ADMIN_PASSWORD`): changing the password in `env.local` and recreating the container is enough. The platform GeoServer's WMS stores keep the datastore password they were created with.
- **`scripts/harden-wms.sh` runs after every `geoserver_setup`** (new imagery layers are queryable by default): PNG/JPEG only, memory and time caps, `dynamicStylingDisabled`, imagery layers `queryable=false`, WCS off on both GeoServers. The 3.0 element names are the same as 2.15 (`getMapMimeTypeCheckingEnabled`, `getMapMimeTypes`, `maxRequestMemory`, `maxRenderingTime`).
- **A GeoServer 3 cascade with `fullWMS` off hangs**: failed `GridAlignmentMismatchException` requests exhaust the 6-connection pool to the datastore, and later requests hang. Set `fullWMS`, then `POST /rest/reset` on the platform GeoServer or recreate it.
- **The wrapper now returns compose's exit status.** It used to end with the nginx loop's status, so failed `run` commands exited 0.
- **Server-to-server calls must use internal addresses** (`http://magpie:2001`, `http://geoserver:8080`), never `https://${HOST_FQDN}`: with `HOST_FQDN=localhost` that resolves to the calling container itself. The API's `GEOIMAGENET_API_MAGPIE_URL` used the public URL, so it couldn't identify users locally.
- **Adding many images: `geoserver_setup` may fail half the mirror layers** with "Could not find layer ... in the server capabilities document" (500). The mirror's WMS stores cache the datastore's capabilities from before the new layers existed. Fix: `POST /geoserver/rest/reset` on both GeoServers, then rerun `geoserver_setup --setup-datastore` (it skips what exists). Seen with 39 new images on 2026-11-27.
- **Convert imagery to COG with an internal mask** (`gdal_translate -of COG ... -mask 1`, command in README.md). GeoServer 2.15's styles drew NoData pixels as opaque black; GeoServer 3 (JAI-EXT) treats `NoData=0` correctly even without the mask (tested), but keep the mask: it costs nothing. Keep the original outside the published folder (`/nas/originals/`). After replacing a file, `POST /rest/reset` on both GeoServers and truncate the datastore's cache layer by layer (`<truncateLayer>`; `<truncateAll>` returns 500).
- **Annotation statuses** (`geoimagenet_api/endpoints/annotations/status.py`):
  - The owner can move `new` to `released` or `deleted`.
  - Any validator can move `released` to `validated` or `rejected`.
  - Nothing goes back to `new`.
  - The frontend's Edit mode only reaches the user's own `new` annotations. A rejected annotation is fixed by drawing a new one.
  - `PUT /annotations` only checks ownership, not status: the old `annotation_update_check` trigger function exists but is attached to no trigger.
  - Validators only see annotations from users they follow.

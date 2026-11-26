# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Deployment orchestration only for the GeoImageNet platform (CRIM). There is no application source here, no build, and no tests. The app code lives in separate repos (`crim-ca/geoimagenet-api`, `-frontend`, `-ml`, `-graphql`) and is consumed as pinned Docker images. Branch `feature/annotation-only` (the deployed one) keeps only annotation: the `ml`, `graphql` and `mongodb` services are removed. See `../DEPLOYMENT_PLAN.md` for the full analysis, the deployment plan, the modernization roadmap and the cloud hosting options.

## Source repos for the custom images

| Repo | Tag | Image |
|---|---|---|
| `sfoucher/geoimagenet-api` (fork of `crim-ca/`), branch `fix/build-2026` | `1.4.2-gin.1` (upstream base 1.4.2) | `ghcr.io/sfoucher/geoimagenet-api`: `api` (also used by `migrations` and `geoserver_setup`) |
| `sfoucher/geoimagenet-frontend` (fork of `crim-ca/`), branch `fix/build-2026` | `1.8.3-gin.2` (static image, not yet published; gin.1 builds at start; upstream base 1.8.3) | `ghcr.io/sfoucher/geoimagenet-frontend`: static files in the nginx image mount (`/public`) |
| `crim-ca/geoimagenet-ml` | `2.2.1` | `ml` |
| `crim-ca/geoimagenet-graphql` | `0.2.4` | `graphql` |

- The tags must match the image tags in `docker-compose.yml`. Bump both together.
- `api` and `frontend` don't build from the tags any more: use branch `fix/build-2026` of the forks `sfoucher/geoimagenet-api` (dependencies pinned to 2020 releases, `geoserver_setup` fixes) and `sfoucher/geoimagenet-frontend` (ML pages hidden).
- `ml` and `graphql` are unused on `feature/annotation-only`. The `ml` build also installs `crim-ca/gin-model-repo@1.0.1` (from GitHub) and `thelper==0.6.2` (from PyPI). Neither needs cloning unless you modify it.
- No public source exists for `geoimagenet/geoserver:2.14.0`. Substitute `kartoza/geoserver:2.15.0` via the override file (no kartoza 2.14 tag exists).
- `crim-ca/geoimagenet` contains only example notebooks for model packaging; the platform doesn't need it.
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
- Every variable in `VARS` must be non-empty, or the wrapper exits with status 1.
- Local overrides (ports, CORS, dev SSL settings, image swaps) belong in `docker-compose.override.yml`, which is gitignored. README.md has the local-dev override and the self-signed certificate steps.
- The version string lives in two places that are kept in sync by bump2version (`setup.cfg`): `canarie_api_config.py.template` and `doc.html.template` (the `GEOIMAGENET_VERSION` line went with the `frontend` service).

## Architecture (big picture)

- **Entry point:** `nginx` (the `pavics/canarieapi` image, which bundles nginx and the CANARIE monitoring app on :2000). Routing is in `config/nginx/conf.d/geoimagenet.conf.template`.
  - `/` serves the static frontend from an image mount (`type: image`) of `ghcr.io/sfoucher/geoimagenet-frontend` on nginx's `/public`; there is no `frontend` container or `dist` volume. `/config.js` is not in the image: nginx generates it (`return 200` in `geoimagenet.conf.template`, from `HOST_FQDN` and `CONTACT_EMAIL`). `pull` skips image-mount sources: `docker pull <ref>` after bumping it. Local frontend dev: see the override examples.
  - `/graphql` and `/ml` are removed on `feature/annotation-only`. The `api` environment still defines `GRAPHQL_ENDPOINT`, `ML_ENDPOINT` and `GEOIMAGENET_API_BATCH_CREATION_URL`; nothing calls them.
  - `/magpie` goes to `magpie:2001`.
  - `/api` and `/geoserver` go to `twitcher:8001/ows/proxy/<name>`.
- **Auth:** Magpie stores users and permissions. Twitcher is the security proxy that asks Magpie (`MagpieAdapter`) before forwarding. A service only gets protected routing if it is registered in `config/magpie/providers.cfg`; permissions are in `permissions.cfg`.
- **Databases:**
  - One PostGIS container holds the `gis` db (api annotations, migrated by the `migrations` job), the `magpie` db and the `twitcher` db.
- **One-shot jobs:**
  - `migrations` runs alembic on the `gis` db.
  - `geoserver_setup` uses the api image to mirror layers from an upstream GeoServer (`GEOIMAGENET_API_GS_DATASTORE_URL`) into the local one, configured by `config/api/geoserver_config.yaml`.
- **Storage:** all named volumes are bind mounts to fixed host paths (`/nas` holds the imagery; `/data/...` holds the databases, ML files and backups). Compose fails at mount time if a directory is missing.

## Gotchas

- **PostGIS breaks after an unnecessary image pull** (`could not access file "$libdir/postgis-2.5"`): the `9.6-2.4` tag was re-pushed with a different build. Third-party images are now pinned to the digest running on the VM (`tag@sha256:...`); never replace a PostGIS digest with a freshly resolved one. Pull only the images you are updating. The recovery procedure (wipe the data dir, re-init, `pg_restore` from `/data/postgis_backups`) is in README.md.
- **The wrapper calls the `docker compose` v2 plugin** (changed from the v1 `docker-compose` binary on branch `docs/deployment-plan`). Hosts with only v1 need the plugin installed.
- **`api` and `frontend` come from GHCR** (`ghcr.io/sfoucher/`), built by GitHub Actions in the forks when a `v*` tag is pushed (release routine in README.md, Versioning). A local `docker-compose.override.yml` can build them from the sibling repos instead (commented block in the override examples; it sets `image:` on `api`, `migrations` and `geoserver_setup`). Package visibility must be set to Public once in the GitHub UI.
- **GeoServer is set to `-Xmx10G`.** Reduce it in the override file on hosts with less than about 24 GB of RAM. With the kartoza image, set `MAXIMUM_MEMORY` and replace `JAVA_OPTS`: its entrypoint appends its own heap flags, built from `MAXIMUM_MEMORY`, after `JAVA_OPTS`.
- **`docker-compose.override.yml.example`** is the working local override (source builds, kartoza GeoServer, 4 GB heap). Copy it to `docker-compose.override.yml`.
- **Secrets come only from `env.local`** (on branch `feature/annotation-only`). Generate each with `openssl rand -hex 32`; hex avoids escaping in the Twitcher database URL. The default passwords, the GitHub OAuth secret and the Slack webhook were removed from the tracked files, but they remain in Git history and in CRIM's public repository, so CRIM must revoke the OAuth secret and the webhook.
- **First initialization is one command** (`up -d --wait`). It used to have three traps, now handled in the compose file; don't undo them:
  - `pg_isready` succeeds before the kartoza image has created the user, so the PostGIS healthcheck does a real TCP login.
  - Only the `gis` database is created automatically; the one-shot `db_init` creates `magpie` and `twitcher`.
  - Concurrent Magpie workers corrupt its first database migration; `preload_app = true` in `magpie.ini.template` runs it once in the gunicorn master.
- **Stop the platform with `down`, not `stop`**: `magpie`, `twitcher` and `nginx` have `restart: always` and would come back alone at the next boot. `down` keeps all data (bind mounts and named volumes).
- **Servers use `docker-compose.override.server.yml.example`**: the local example publishes GeoServer on 8600, bypassing Twitcher, and disables Magpie SSL verification.
- **nginx keeps the IP it resolved at start** for `twitcher` and `magpie`. `depends_on: restart: true` restarts it on `compose restart <svc>` but **not** on `up --force-recreate <svc>` (tested), so the wrapper still restarts nginx after every `up`. Keep both.
- **Keep the Twitcher ACL cache disabled** (`cache.regions = acl` in `twitcher.ini.template`): incompatible with route-level permissions in Magpie 1.6.
- **Imagery path:** the platform's `geoserver` cascades WMS from a separate datastore GeoServer (`geoserver-datastore` locally, see the override example), which serves the GeoTIFFs from `/nas`. `geoserver_setup --setup-datastore` configures both. The datastore's tile cache needs `<fullWMS>true</fullWMS>` in `gwc/geowebcache.xml`. Add it **after** the first `geoserver_setup`: before that, the file has no `<layers/>` line and the README's `sed` changes nothing (it prints the match count; 1 means it worked).
- **Never use `_` in a GeoServer container name** others call over HTTP: Tomcat answers 400 to such Host headers.
- **If a kartoza/geoserver 2.15 container answers 404 on `/geoserver` after a restart, recreate it** (`up -d --force-recreate <service>`). It happened once (Tomcat `StackOverflowError` scanning annotations); later restarts of both GeoServers worked.
- **The wrapper now returns compose's exit status.** It used to end with the nginx loop's status, so failed `run` commands exited 0.
- **Server-to-server calls must use internal addresses** (`http://magpie:2001`, `http://geoserver:8080`), never `https://${HOST_FQDN}`: with `HOST_FQDN=localhost` that resolves to the calling container itself. The API's `GEOIMAGENET_API_MAGPIE_URL` used the public URL, so it couldn't identify users locally.
- **GeoServer's admin password is applied on first start only** (kartoza writes a lock file into the data dir). Changing `GEOIMAGENET_API_GS_MIRROR_PASSWORD` later needs the password changed in GeoServer too.
- **Convert imagery to COG with an internal mask** (`gdal_translate -of COG ... -mask 1`, command in README.md). GeoServer 2.15's RGB and NRG styles ignore the NoData value and draw NoData pixels as opaque black bands. The mask makes them transparent. Keep the original outside the published folder (`/nas/originals/`). After replacing a file, `POST /rest/reset` on both GeoServers and truncate the datastore's cache layer by layer (`<truncateLayer>`; `<truncateAll>` returns 500).
- **Annotation statuses** (`geoimagenet_api/endpoints/annotations/status.py`):
  - The owner can move `new` to `released` or `deleted`.
  - Any validator can move `released` to `validated` or `rejected`.
  - Nothing goes back to `new`.
  - The frontend's Edit mode only reaches the user's own `new` annotations. A rejected annotation is fixed by drawing a new one.
  - `PUT /annotations` only checks ownership, not status: the old `annotation_update_check` trigger function exists but is attached to no trigger.
  - Validators only see annotations from users they follow.

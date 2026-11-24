# GeoImageNet Compose

Deployment of the GeoImageNet annotation platform with Docker Compose. This repo holds no application code: the services run images built from the sibling `geoimagenet-api` and `geoimagenet-frontend` repos.

This guide covers the **annotation-only** setup (branch `feature/annotation-only`, without the ML, GraphQL and MongoDB services). Every procedure below was run end to end on a local WSL2 host on 2026-11-24. The reasons behind each step, the security findings and the hosting options are in [DEPLOYMENT_PLAN.md](DEPLOYMENT_PLAN.md).

- [How it fits together](#how-it-fits-together)
- [Prerequisites](#prerequisites)
- [First installation](#first-installation)
- [Loading imagery](#loading-imagery)
- [Daily operation](#daily-operation)
- [Users and roles](#users-and-roles)
- [Backups and restore](#backups-and-restore)
- [Known traps](#known-traps)
- [Versioning](#versioning)

## How it fits together

```
browser ──HTTPS──► nginx ──► /            static frontend (built by the `frontend` container)
                         ├─► /magpie      Magpie: users, groups, permissions
                         └─► /api, /geoserver ──► Twitcher (asks Magpie) ──► api / geoserver
geoserver ──WMS cascade──► geoserver-datastore ──► GeoTIFFs in /nas
api, geoserver, magpie, twitcher ──► PostGIS (databases gis, magpie, twitcher)
```

Always go through the wrapper `./geoimagenet-compose.sh`, never `docker compose` directly. It sources `env.local`, renders every tracked `*.template` file next to itself (for example `magpie.ini.template` becomes `magpie.ini`), runs `docker compose` with your arguments, and restarts nginx after `up`. Edit the `.template` files, never the rendered ones.

## Prerequisites

- Docker with the Compose v2 plugin (`docker compose version`).
- About 16 GB of RAM (each GeoServer is capped at 4 GB and 2 GB) and disk for the imagery.
- The sibling repos, checked out on their fix branches:

  ```
  ~/DEV/geoimagenet/
  ├── geoimagenet-compose/     this repo, branch feature/annotation-only
  ├── geoimagenet-api/         branch fix/build-2026
  └── geoimagenet-frontend/    branch fix/build-2026
  ```

## First installation

Run everything from this repo's folder.

**1. Local override.** It builds the images from the sibling repos, swaps in `kartoza/geoserver:2.15.0` and adds the datastore GeoServer:

```bash
cp docker-compose.override.yml.example docker-compose.override.yml
```

**2. Configuration.** Copy the example, then fill in every secret with a generated value (`openssl rand -hex 32`; hex avoids escaping problems in database URLs):

```bash
cp env.local.example env.local
chmod 600 env.local
# edit env.local: POSTGIS_PASSWORD, MAGPIE_ADMIN_PW, MAGPIE_SECRET,
# GEOIMAGENET_API_GS_MIRROR_PASSWORD, GEOIMAGENET_API_GS_DATASTORE_PASSWORD
```

Also set:

| Variable | Local value | Server value |
|---|---|---|
| `HOST_FQDN` | `localhost` | the public host name |
| `SSL_CERTIFICATE`, `SSL_PRIVATE_KEY` | the self-signed files from step 3 | the real certificate and key |
| `TWITCHER_SSL_VERIFY` | `false` | `true` |
| `GEOIMAGENET_API_GS_DATASTORE_URL` | `http://geoserver-datastore:8080/geoserver` | same, unless the datastore runs elsewhere |

The wrapper refuses to run (exit status 1) while a required variable is empty.

**3. TLS certificate (local only).** Browsers require the subject alternative name:

```bash
openssl req -x509 -newkey rsa:4096 -nodes -days 825 -keyout key.pem -out cert.pem \
  -subj "/CN=localhost" -addext "subjectAltName=DNS:localhost,IP:127.0.0.1"
chmod 600 key.pem
```

**4. Host directories.** Compose fails at mount time if one is missing:

```bash
sudo mkdir -p /nas /data/db_gis_data /data/geoserver/data_dir \
  /data/geoserver_datastore/data_dir /data/postgis_backups
sudo chown $USER /nas
```

On WSL2, keep these on the Linux filesystem, not under `/mnt/c`.

**5. Build the images.**

```bash
./geoimagenet-compose.sh build
```

**6. Initialize the databases.** Follow this order exactly; each step works around a trap noted in the comments.

```bash
set -a; . ./env.local; set +a
psql_gis() { docker exec -e PGPASSWORD="$POSTGIS_PASSWORD" postgis psql -h localhost -U "$POSTGIS_USER" -d gis -Atc "$1"; }

# PostGIS. pg_isready answers before the first-run setup has created the user: wait for a real login.
./geoimagenet-compose.sh up -d postgis
until psql_gis "select 1" >/dev/null 2>&1; do sleep 2; done

# Only "gis" is created automatically. Magpie and Twitcher need their own databases.
psql_gis "create database magpie owner $POSTGIS_USER"
psql_gis "create database twitcher owner $POSTGIS_USER"

# Schema and taxonomies of the gis database.
./geoimagenet-compose.sh run --rm migrations upgrade head

# Magpie's first start MUST use one worker: concurrent workers corrupt its database migration.
./geoimagenet-compose.sh run -d --name magpie-init magpie \
  gunicorn -b 0.0.0.0:2001 --paste config/magpie.ini --workers 1
until docker logs magpie-init 2>&1 | grep -q "Starting Magpie app"; do sleep 2; done
docker rm -f magpie-init
```

**7. Start the platform.**

```bash
SERVICES="postgis postgis_backups migrations api geoserver geoserver-datastore magpie twitcher frontend nginx"
./geoimagenet-compose.sh up -d $SERVICES
```

The `frontend` container builds the web interface into a shared volume, then exits with status 0 (about a minute). `migrations` also exits with 0. `geoserver_setup` is left out on purpose: it runs when imagery is loaded.

**8. Check.** Open `https://${HOST_FQDN}` and accept the certificate warning if it is self-signed. Log in as `MAGPIE_ADMIN_USER` with `MAGPIE_ADMIN_PW`. The map stays empty until imagery is loaded.

## Loading imagery

The platform's `geoserver` does not read the image files. It cascades WMS from the **datastore GeoServer** (`geoserver-datastore`), which serves the GeoTIFFs in `/nas`. `geoserver_setup` configures both and registers each image in the database.

**1. Prepare each image.** Requirements (details in DEPLOYMENT_PLAN.md §10.2):

- 8-bit, 4 bands in R, G, B, NIR order (or 3-band RGB).
- File name matching `Pleiades_<YYYYMMDD>_<BANDS>_50cm_<BITS>bits_AOI_<n>_<City>_<PROV>.tif`. `50cm` is fixed text in the pattern.
- A footprint shapefile named `..._trace.shp` (with `.shx`, `.dbf`, `.prj`). It is required: without it, `geoserver_setup` fails. Use CRIM's original traces when you have them; they match the 8-bit images even if their names say `16bits`.

Convert to a Cloud-Optimized GeoTIFF (tiles and overviews make GeoServer much faster) and, if there is no original trace, compute one:

```bash
G="docker run --rm -u $(id -u):$(id -g) -v /path/to/source:/in:ro -v /nas:/nas ghcr.io/osgeo/gdal:ubuntu-small-3.9.3"
N=Pleiades_20141025_RGBN_50cm_8bits_AOI_1_Sherbrooke_QC

mkdir -p /nas/PLEIADES_RGBN_8 /nas/PLEIADES_CONTOURS
$G gdal_translate -of COG -co COMPRESS=DEFLATE -co PREDICTOR=2 -co BLOCKSIZE=512 \
   -co OVERVIEW_RESAMPLING=AVERAGE /in/$N.tif /nas/PLEIADES_RGBN_8/$N.tif
# only without an original trace:
$G gdal_footprint -ovr 3 -of "ESRI Shapefile" /nas/PLEIADES_RGBN_8/$N.tif /nas/PLEIADES_CONTOURS/${N}_trace.shp
```

Resulting layout:

```
/nas/PLEIADES_RGBN_8/<image>.tif
/nas/PLEIADES_CONTOURS/<image or 16-bit master>_trace.{shp,shx,dbf,prj}
```

The imagery is licensed (Airbus). Keep it out of Git and of any public storage.

**2. Enable "full WMS" on the datastore (once per datastore).** The cascade sends requests that are not aligned to the datastore's tile grid; without this setting they fail with 400.

```bash
docker exec geoserver-datastore sh -c 'f=/opt/geoserver/data_dir/gwc/geowebcache.xml; grep -q "<fullWMS>" $f || sed -i "s|^  <layers/>$|  <layers/>\n  <fullWMS>true</fullWMS>|" $f'
./geoimagenet-compose.sh up -d --force-recreate geoserver-datastore
```

**3. Publish.** Rerun this after adding images; it skips what already exists.

```bash
./geoimagenet-compose.sh run --rm geoserver_setup --setup-datastore
```

It must end without a traceback. Each image is then listed as `PLEIADES_RGB:<image>` and `PLEIADES_NRG:<image>` in the map's layer switcher.

## Daily operation

```bash
SERVICES="postgis postgis_backups migrations api geoserver geoserver-datastore magpie twitcher frontend nginx"

./geoimagenet-compose.sh up -d $SERVICES     # start, or bring everything back after a reboot
./geoimagenet-compose.sh stop                # stop, keeping the containers
./geoimagenet-compose.sh ps                  # status
./geoimagenet-compose.sh logs -f api         # follow one service
```

- **After a reboot, run the `up -d` line.** Docker does not restart the platform's `geoserver` on its own (its restart policy is `on-failure`), so the map stays empty until you do.
- **After restarting a single service, restart nginx too**, or nginx keeps the old container address and returns 502:

  ```bash
  ./geoimagenet-compose.sh restart twitcher && ./geoimagenet-compose.sh restart nginx
  ```

  `up` restarts nginx automatically; `restart` does not.
- **If a GeoServer answers 404 on `/geoserver` after a restart, recreate it:** `./geoimagenet-compose.sh up -d --force-recreate geoserver` (or `geoserver-datastore`). It happened once with the kartoza 2.15 image.
- **Never run a bare `pull`.** Pulling the PostGIS image unnecessarily can break it (see [Backups and restore](#backups-and-restore)). Name the images you mean to update.

## Users and roles

Manage accounts in Magpie's administration interface, `https://${HOST_FQDN}/magpie/`: log in as the admin, then go to **Users**. Each user belongs to one role group:

| Group | Can do |
|---|---|
| `annotators` | draw, edit, release and delete their own annotations; see the imagery |
| `validators` | validate or reject released annotations; see the imagery |
| `full` | both of the above |
| `administrators` | everything |
| `anonymous` | (no login) read the public annotations and taxonomy; no imagery |

The same can be scripted with Magpie's API:

```bash
set -a; . ./env.local; set +a
curl -sk -c /tmp/mc -X POST https://localhost/magpie/signin -H 'Content-Type: application/json' \
  -d "{\"user_name\":\"$MAGPIE_ADMIN_USER\",\"password\":\"$MAGPIE_ADMIN_PW\"}"
curl -sk -b /tmp/mc -X POST https://localhost/magpie/users -H 'Content-Type: application/json' \
  -d '{"user_name":"jdoe","email":"jdoe@example.org","password":"<generated>","group_name":"annotators"}'
rm /tmp/mc
```

**The annotation workflow, and what users must know:**

1. The annotator draws an annotation (status `new`), then **releases** it. A `new` annotation never reaches validators.
2. **A validator only sees the annotations of the users they follow.** Each validator must add their annotators in the user settings ("followed users"). Without it, the validation list stays empty: "there are no annotations on the current page".
3. The validator validates or rejects released annotations. **The "Validate/Reject current page's annotations" button rejects every annotation whose box is unchecked**, and clicking a row unchecks it. Rejection is final. To validate one annotation, click its polygon in Validate mode instead.

Validated annotations are public: `GET https://${HOST_FQDN}/api/v1/batches/annotations` returns them as GeoJSON without login.

## Backups and restore

`postgis_backups` dumps every database (`gis`, `magpie`, `twitcher`) each day at 23:00 UTC into `/data/postgis_backups/<year>/<month>/`. To run one now:

```bash
docker exec postgis_backups /backups.sh
ls -l /data/postgis_backups/$(date +%Y)/$(date +%B)/
```

The dumps stay on the same host. Copy them elsewhere for a real backup. The backup container prints its environment, including the database password, to `docker logs postgis_backups`: treat access to the Docker logs as access to the database.

**Restore** (for example after the known PostGIS failure, `could not access file "$libdir/postgis-2.5"` in the PostGIS logs, typically after an unnecessary `pull`):

```bash
./geoimagenet-compose.sh down
sudo rm -rf /data/db_gis_data/*
docker rmi kartoza/postgis:9.6-2.4

# re-create PostGIS and the magpie and twitcher databases: "First installation", step 6, up to and
# including the migrations (skip the Magpie init: the restored dump contains its tables)

set -a; . ./env.local; set +a
D=/data/postgis_backups/2026/November           # pick the dump folder and date
for db in magpie gis; do
  docker exec -i -e PGPASSWORD="$POSTGIS_PASSWORD" postgis \
    pg_restore -h localhost -U "$POSTGIS_USER" -d $db -c < $D/geoimagenet_$db.24-November-2026.dmp
done
SERVICES="postgis postgis_backups migrations api geoserver geoserver-datastore magpie twitcher frontend nginx"
./geoimagenet-compose.sh up -d $SERVICES
```

`pg_restore` may report that it cannot drop the PostGIS extension; that error is harmless.

## Known traps

| Symptom | Cause and fix |
|---|---|
| Wrapper error "Required variable X is not set" | Fill in `X` in `env.local`. |
| `password authentication failed` right after starting PostGIS for the first time | PostGIS was still in its first-run setup. Wait for a real login (installation step 6). |
| Magpie logs `duplicate key` or `expected to match one row` on first start | It started with several workers. Drop and re-create the `magpie` database, then run the single-worker init. |
| 502 from nginx after restarting a service | Restart nginx. |
| Every call to a GeoServer container returns 400 | Its name contains `_`; Tomcat rejects such host names. Use `-`. |
| Map tiles fail with "Content type is required" | "Full WMS" is off on the datastore (Loading imagery, step 2). |
| Users get "There was a problem connecting to magpie" | The API must reach Magpie at `http://magpie:2001` (`GEOIMAGENET_API_MAGPIE_URL`), never through `https://${HOST_FQDN}`. |
| Annotations or imagery visible without login | Check `config/magpie/permissions.cfg`. Keep the Twitcher ACL cache disabled: it is incompatible with route-level permissions in Magpie 1.6. |

## Versioning

We use bump2version: `pip install bump2version`. Bump the version with `make VERSION=<target_tag> bump` (`make VERSION=<target_tag> dry bump` to preview).

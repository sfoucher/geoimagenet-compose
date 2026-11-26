# GeoImageNet Compose

Deployment of the GeoImageNet annotation platform with Docker Compose. This repo holds no application code: the services run images built from the sibling `geoimagenet-api` and `geoimagenet-frontend` repos.

This guide covers the **annotation-only** setup (branch `feature/annotation-only`, without the ML, GraphQL and MongoDB services). Every procedure below was run end to end on a local WSL2 host on 2026-11-24. The reasons behind each step, the security findings and the hosting options are in the deployment plan, [`../DEPLOYMENT_PLAN.md`](../DEPLOYMENT_PLAN.md) (kept outside this repo).

- [How it fits together](#how-it-fits-together)
- [Prerequisites](#prerequisites)
- [First installation](#first-installation)
- [Loading imagery](#loading-imagery)
- [Daily operation](#daily-operation)
- [Deploying on a local Linux server](#deploying-on-a-local-linux-server)
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

**6. Start the platform.** One command. Compose orders the start by health:
- PostGIS is healthy only once a real login works;
- `db_init` creates the `magpie` and `twitcher` databases if they are missing;
- `migrations` creates the schema and the taxonomies of `gis`;
- Magpie runs its database migration once before its workers start (`preload_app` in `magpie.ini`);
- then the API, Twitcher, the GeoServers and nginx start.

```bash
./geoimagenet-compose.sh up -d --wait
```

`--wait` returns once every service is healthy. The `frontend` container builds the web interface into a shared volume, then exits with status 0 (about a minute). `db_init` and `migrations` also exit with 0. `geoserver_setup` belongs to the `setup` profile, so `up` doesn't start it: it runs when imagery is loaded.

**7. Check.** Open `https://${HOST_FQDN}` and accept the certificate warning if it is self-signed. Log in as `MAGPIE_ADMIN_USER` with `MAGPIE_ADMIN_PW`. The map stays empty until imagery is loaded.

## Loading imagery

The platform's `geoserver` does not read the image files. It cascades WMS from the **datastore GeoServer** (`geoserver-datastore`), which serves the GeoTIFFs in `/nas`. `geoserver_setup` configures both and registers each image in the database.

**1. Prepare each image.** Requirements (details in `../DEPLOYMENT_PLAN.md` §10.2):

- 8-bit, 4 bands in R, G, B, NIR order (or 3-band RGB).
- File name matching `Pleiades_<YYYYMMDD>_<BANDS>_50cm_<BITS>bits_AOI_<n>_<City>_<PROV>.tif`. `50cm` is fixed text in the pattern.
- A footprint shapefile named `..._trace.shp` (with `.shx`, `.dbf`, `.prj`). It is required: without it, `geoserver_setup` fails. Use CRIM's original traces when you have them; they match the 8-bit images even if their names say `16bits`.

Convert to a Cloud-Optimized GeoTIFF (tiles and overviews make GeoServer much faster) with an internal transparency mask, and, if there is no original trace, compute one. The source must declare its border pixels as NoData (`gdalinfo` shows `NoData Value=0`). `-mask 1` turns that NoData into an internal mask: GeoServer 2.15 draws NoData pixels opaque black through the RGB and NRG styles, but it does honour the mask, so the borders become transparent.

```bash
G="docker run --rm -u $(id -u):$(id -g) -v /path/to/source:/in:ro -v /nas:/nas ghcr.io/osgeo/gdal:ubuntu-small-3.9.3"
N=Pleiades_20141025_RGBN_50cm_8bits_AOI_1_Sherbrooke_QC

mkdir -p /nas/PLEIADES_RGBN_8 /nas/PLEIADES_CONTOURS
$G gdal_translate -of COG -co COMPRESS=DEFLATE -co PREDICTOR=2 -co BLOCKSIZE=512 \
   -co OVERVIEW_RESAMPLING=AVERAGE -mask 1 /in/$N.tif /nas/PLEIADES_RGBN_8/$N.tif
# only without an original trace:
$G gdal_footprint -ovr 3 -of "ESRI Shapefile" /nas/PLEIADES_RGBN_8/$N.tif /nas/PLEIADES_CONTOURS/${N}_trace.shp
```

Resulting layout:

```
/nas/PLEIADES_RGBN_8/<image>.tif
/nas/PLEIADES_CONTOURS/<image or 16-bit master>_trace.{shp,shx,dbf,prj}
```

The imagery is licensed (Airbus). Keep it out of Git and of any public storage.

**2. Publish.** Rerun this after adding images; it skips what already exists.

```bash
./geoimagenet-compose.sh run --rm geoserver_setup --setup-datastore
```

It must end without a traceback. Each image is then listed as `PLEIADES_RGB:<image>` and `PLEIADES_NRG:<image>` in the map's layer switcher.

**3. Enable "full WMS" on the datastore (once per datastore, after the first publish).** The cascade sends requests that are not aligned to the datastore's tile grid; without this setting they fail with 400. It must come after the first `geoserver_setup`: a fresh datastore only writes the `<layers/>` line this command edits during its first configuration (otherwise the command silently changes nothing; it should print `1`).

```bash
docker exec geoserver-datastore sh -c 'f=/opt/geoserver/data_dir/gwc/geowebcache.xml; grep -q "<fullWMS>" $f || sed -i "s|^  <layers/>$|  <layers/>\n  <fullWMS>true</fullWMS>|" $f; grep -c "<fullWMS>true" $f'
./geoimagenet-compose.sh up -d --force-recreate geoserver-datastore
```

**4. Restrict the platform GeoServer's WMS (once per data dir).** Logged-in users may read the whole `geoserver` service, and by default its `GetMap` also returns georeferenced GeoTIFF, KMZ, and images of any size, which amounts to a download of the imagery. The script limits `GetMap` to PNG and JPEG and caps the memory and rendering time of each request, which caps the image at about 2048×2048 px. nginx also answers 404 on `/geoserver/web` and `/geoserver/rest`.

```bash
./scripts/harden-wms.sh          # prints the new settings
```

## Daily operation

```bash
./geoimagenet-compose.sh up -d --wait       # start, or bring everything back after a reboot
./geoimagenet-compose.sh down                # stop and remove the containers; all data is kept
./geoimagenet-compose.sh ps                  # status
./geoimagenet-compose.sh logs -f api         # follow one service
```

- **Stop with `down`, not `stop`.** `magpie`, `twitcher` and `nginx` have `restart: always`: after `stop`, Docker starts them again by itself at the next boot, leaving a half-started platform on port 443. `down` removes the containers but none of the data (databases, GeoServer configuration and imagery are in `/data` and `/nas`; `down` without `-v` keeps the volumes), and `up -d` recreates them identically. Verified on 2026-11-25.
- **After a reboot, run the `up -d --wait` line.** Docker does not restart the platform's `geoserver` on its own (its restart policy is `on-failure`), so the map stays empty until you do.
- **nginx and a recreated service.** nginx resolves `twitcher` and `magpie` once, at start, so a recreated container with a new address would give 502. Both cases are handled: `./geoimagenet-compose.sh restart twitcher` (or `magpie`) restarts nginx through `depends_on: restart: true`, and the wrapper restarts nginx after every `up`.
- **If a GeoServer answers 404 on `/geoserver` after a restart, recreate it:** `./geoimagenet-compose.sh up -d --force-recreate geoserver` (or `geoserver-datastore`). It happened once with the kartoza 2.15 image.
- **Never run a bare `pull`.** Pulling the PostGIS image unnecessarily can break it (see [Backups and restore](#backups-and-restore)). Name the images you mean to update.

## Deploying on a local Linux server

The same procedure on a dedicated Linux machine (physical or VM) on your network, used **on demand**: started for an annotation period, stopped in between. Not yet tried on such a server; the differences from the WSL setup are below.

**1. Hardware**

| Resource | Minimum | Recommended | Why |
|---|---|---|---|
| CPU | 4 cores | 8 cores | map tile rendering |
| RAM | 16 GB | 32 GB | 8–9 GB peak measured, plus the OS and the page cache for the imagery |
| System and `/data` | 150 GB SSD | 250 GB SSD | databases, tile cache, Docker images, dumps |
| `/nas` | 600 GB | 1 TB or more, on RAID 1 | 500 GB of imagery and room to grow |
| Network | fixed IP | fixed IP and a DNS name | `HOST_FQDN` is compiled into the frontend |

**2. System.** Ubuntu Server 24.04 LTS (or Debian 12). Install Docker Engine and the Compose plugin from Docker's repository. Mount the SSD at `/data` and the imagery disk at `/nas` in `/etc/fstab` (by UUID). Add 4 GB of swap, and limit the Docker logs in `/etc/docker/daemon.json`:

```json
{ "log-driver": "json-file", "log-opts": { "max-size": "50m", "max-file": "3" } }
```

**3. Access, host name and certificate.** Users' browsers call the URLs compiled into the frontend, so `HOST_FQDN` must be a name they can resolve, **never `localhost`**:

| Access | `HOST_FQDN` | Certificate |
|---|---|---|
| Internal network only (lab, VPN) | a name in your internal DNS, for example `geoimagenet.lab.example.ca` | your organization's internal CA, or Let's Encrypt with the DNS-01 challenge if the domain is public (no port to open) |
| Internet | a public name pointing to the router | Let's Encrypt (HTTP-01 through port 80, forwarded by the router) |

A self-signed certificate is only for a quick test: every browser warns about it.

**4. Firewall.** Only nginx publishes ports (80 and 443). Docker bypasses `ufw` for published ports, so filter at the network level (router or firewall), or in the `DOCKER-USER` iptables chain. Allow SSH only from administrators' machines.

**5. Code and configuration.**

```bash
mkdir -p ~/geoimagenet && cd ~/geoimagenet
git clone -b feature/annotation-only https://github.com/sfoucher/geoimagenet-compose
git clone -b fix/build-2026 https://github.com/sfoucher/geoimagenet-api
git clone -b fix/build-2026 https://github.com/sfoucher/geoimagenet-frontend
cd geoimagenet-compose
cp docker-compose.override.server.yml.example docker-compose.override.yml
cp env.local.example env.local && chmod 600 env.local
```

**Use the server override**, `docker-compose.override.server.yml.example`. It differs from the local one in two settings: GeoServer is not published on port 8600 (which would bypass Twitcher's access control), and Magpie SSL verification stays on. In `env.local`: new secrets (`openssl rand -hex 32`), the real `HOST_FQDN`, the certificate paths, and `TWITCHER_SSL_VERIFY=true`.

**6. Install** with [First installation](#first-installation), steps 4 to 7.

**7. Data: start fresh or migrate.**

- **Start fresh:** copy the imagery (`rsync -a --info=progress2 <source>/ <server>:/nas/`), then follow [Loading imagery](#loading-imagery).
- **Migrate an existing deployment**, keeping accounts, annotations and GeoServer configuration: on the old host, run a backup (`docker exec postgis_backups /backups.sh`) and copy the dumps, `/nas` and `/data/geoserver*/data_dir` to the server with `rsync`. On the server, restore the dumps as in [Backups and restore](#backups-and-restore) instead of running installation step 6 on empty databases. Keep the old GeoServer passwords in `env.local`: GeoServer applies a new admin password on first start only.

**8. Run it on demand.**

```bash
cd ~/geoimagenet/geoimagenet-compose

# start an annotation period (about a minute: the frontend rebuilds)
sudo apt update && sudo apt upgrade        # the machine is often off: update at each start
sudo certbot renew                         # Let's Encrypt only; does nothing if still valid
./geoimagenet-compose.sh up -d --wait

# end of the period
docker exec postgis_backups /backups.sh    # the 23:00 automatic dump only runs if the server is up
rsync -a /data/postgis_backups/ <backup-host>:geoimagenet-backups/
./geoimagenet-compose.sh down
```

- **Use `down` to stop**, not `stop`, or `magpie`, `twitcher` and `nginx` start again by themselves at the next boot.
- **Back up at the end of each period** and copy the dumps off the machine. RAID protects against a disk failure, not against a mistake or a lost server. Keep an offline copy of the imagery too.
- **Let's Encrypt certificates last 90 days** and only renew while the server is on, hence `certbot renew` at each start. A certificate from an internal CA, valid for years, avoids this.
- **Don't `pull` Docker images.** The api and frontend images are built locally and only change when you rebuild them; pulling PostGIS needlessly can break it (see [Known traps](#known-traps)).

**9. Check from another machine on the network:** log in, imagery, annotation, validation, export (as in the step 11 checks of the plan), and that only ports 80 and 443, plus 22 from your machine, answer (`nmap <server>`).

## Resizing an OpenStack instance

To change the CPU and RAM of a cloud VM (for example on the Alliance's Arbutus cloud). With an instance **booted from a volume** whose volumes all have `delete_on_termination: false`, a resize changes only CPU and RAM: the boot volume, `/data` and `/nas` stay attached, nothing to copy. Check first:

```bash
openstack server show <server> -c flavor -c image -c volumes_attached   # image: "booted from volume"
openstack quota show                                                    # cores and ram
openstack flavor list
```

A flavor larger than the project's `cores` or `ram` quota is refused: ask the cloud's support for a quota increase first.

```bash
ssh <vm> 'cd ~/geoimagenet/geoimagenet-compose && ./geoimagenet-compose.sh down'
openstack server resize --flavor <new-flavor> <server>
openstack server show <server> -c status        # wait for VERIFY_RESIZE
openstack server resize confirm <server>        # or "resize revert" to go back
ssh <vm> 'df -h /data /nas'                     # volumes mounted
ssh <vm> 'cd ~/geoimagenet/geoimagenet-compose && ./geoimagenet-compose.sh up -d'
```

- **About 5 minutes of downtime**, plus a minute for the frontend rebuild.
- **If the resize is refused**, delete the instance and create a new one from the same boot volume (`openstack server create --volume <boot-volume> --flavor <new-flavor> ...`), then attach the data volumes and the floating IP again. The IP and the DNS name don't change, so the certificate stays valid.
- **With more RAM, raise the GeoServer heap** (`MAXIMUM_MEMORY` in `docker-compose.override.yml`), then `up -d --force-recreate geoserver geoserver-datastore`.

## Users and roles

Accounts, groups and permissions live in Magpie. The administrator account is `MAGPIE_ADMIN_USER` / `MAGPIE_ADMIN_PW` from `env.local`; there is no self-registration, so the administrator creates every account.

### Roles

Each person gets **one role group** (all accounts are also in `anonymous` automatically):

| Group | Can do in the platform |
|---|---|
| `annotators` | draw, edit, release and delete their own annotations; see the imagery |
| `validators` | validate or reject the released annotations of the users they follow; see the imagery |
| `full` | both of the above |
| `administrators` | everything, including Magpie administration |
| `observers` | read-only access to the API and GeoServer (for scripts or GIS clients); the web interface doesn't show them the imagery, since they lack the frontend `wms` permission |
| `anonymous` | (no login) the public annotations and taxonomy; no imagery |

### With the administration interface

Open `https://${HOST_FQDN}/magpie/` and log in as the administrator.

- **Create an account:** **Users** → **Add User**. Fill in the user name, email, password and group, then **Add User**. Give the person their user name and password through a private channel.
- **Change a password, email or role:** **Users** → **Edit** on the person's row. Change the password or email, and check or uncheck groups under the group memberships.
- **Remove someone's access:** uncheck their role group (they keep an account but can only do what `anonymous` can), or **Delete** the account.

Deleting an account doesn't delete its annotations; they stay in the database with the author's numeric ID. Removing the role group is usually enough.

### With the API (scripts, many accounts)

The same operations through Magpie's REST API, verified on 2026-11-24:

```bash
set -a; . ./env.local; set +a
M=https://${HOST_FQDN}/magpie
curl -sk -c /tmp/mc -X POST $M/signin -H 'Content-Type: application/json' \
  -d "{\"user_name\":\"$MAGPIE_ADMIN_USER\",\"password\":\"$MAGPIE_ADMIN_PW\"}"

PW=$(openssl rand -base64 12)                                   # give it to the person privately
curl -sk -b /tmp/mc -X POST $M/users -H 'Content-Type: application/json' \
  -d "{\"user_name\":\"jdoe\",\"email\":\"jdoe@example.org\",\"password\":\"$PW\",\"group_name\":\"annotators\"}"

curl -sk -b /tmp/mc $M/users/jdoe                               # details, including the numeric user_id
curl -sk -b /tmp/mc $M/users/jdoe/groups                        # groups
curl -sk -b /tmp/mc -X POST $M/users/jdoe/groups -H 'Content-Type: application/json' \
  -d '{"group_name":"validators"}'                              # add a role
curl -sk -b /tmp/mc -X DELETE $M/users/jdoe/groups/annotators   # remove a role
curl -sk -b /tmp/mc -X PUT $M/users/jdoe -H 'Content-Type: application/json' \
  -d '{"password":"<new password>"}'                            # reset the password
curl -sk -b /tmp/mc -X DELETE $M/users/jdoe                     # delete the account
curl -sk -b /tmp/mc $M/users                                    # list all accounts

rm /tmp/mc
```

`POST /users` answers 201 when the account is created; the other calls answer 200 or 201.

### Setting up a validator: following annotators

**A validator only sees the annotations of the users they follow.** In Validate mode the interface shows "released annotations by me or by users I follow" and nothing else. A new validator follows nobody, so their validation list is empty ("there are no annotations on the current page"). Set this up once for each validator:

1. Find each annotator's **numeric user ID**: on the map, an annotation from someone you don't follow is labelled `<class> : user <ID>` (for example `Cropland : user 3`). The administrator can also read it in Magpie (`GET /magpie/users/<name>`, field `user_id`).
2. Log in to the platform as the validator, open the sidebar's **Settings** panel, and under **Followed users** enter the annotator's ID ("Other user's unique id") and a nickname of your choice. Add each annotator the same way.
3. Reload the page. The followed annotators' released annotations now appear in Validate mode, labelled with the nickname.

### The annotation workflow, and what users must know

1. The annotator draws an annotation (status `new`), then **releases** it. A `new` annotation never reaches validators.
2. The validator, following that annotator, validates or rejects it. **The "Validate/Reject current page's annotations" button rejects every annotation whose box is unchecked**, and clicking a row unchecks it. Rejection is final. To validate one annotation, click its polygon in Validate mode instead.
3. Validated annotations are public: `GET https://${HOST_FQDN}/api/v1/batches/annotations` returns them as GeoJSON without login.

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

# re-create PostGIS, the magpie and twitcher databases and the gis schema, without starting
# Magpie (it would migrate its empty database before the restore)
./geoimagenet-compose.sh up -d --wait postgis db_init migrations

set -a; . ./env.local; set +a
D=/data/postgis_backups/2026/November           # pick the dump folder
for db in gis magpie twitcher; do
  f=$(ls -t $D/geoimagenet_$db.*.dmp | head -1)   # newest dump of that database
  docker exec -i -e PGPASSWORD="$POSTGIS_PASSWORD" postgis \
    pg_restore -h localhost -U "$POSTGIS_USER" -d $db -c < "$f"
done
./geoimagenet-compose.sh up -d --wait
```

`pg_restore` may report that it cannot drop the PostGIS extension; that error is harmless.

## Known traps

| Symptom | Cause and fix |
|---|---|
| Wrapper error "Required variable X is not set" | Fill in `X` in `env.local`. |
| `password authentication failed` right after starting PostGIS for the first time | PostGIS was still in its first-run setup. Its healthcheck waits for a real login; start with `up -d --wait`. |
| Magpie logs `duplicate key` or `expected to match one row` on first start | It started with several workers. Drop and re-create the `magpie` database, then run the single-worker init. |
| 502 from nginx after restarting a service | `./geoimagenet-compose.sh restart nginx`. Shouldn't happen with `restart` or `up` (see Daily operation). |
| Every call to a GeoServer container returns 400 | Its name contains `_`; Tomcat rejects such host names. Use `-`. |
| Map tiles fail with "Content type is required" | "Full WMS" is off on the datastore (Loading imagery, step 2). |
| Users get "There was a problem connecting to magpie" | The API must reach Magpie at `http://magpie:2001` (`GEOIMAGENET_API_MAGPIE_URL`), never through `https://${HOST_FQDN}`. |
| Annotations or imagery visible without login | Check `config/magpie/permissions.cfg`. Keep the Twitcher ACL cache disabled: it is incompatible with route-level permissions in Magpie 1.6. |

## Versioning

We use bump2version: `pip install bump2version`. Bump the version with `make VERSION=<target_tag> bump` (`make VERSION=<target_tag> dry bump` to preview).

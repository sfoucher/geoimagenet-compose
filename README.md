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
browser ──HTTPS──► nginx ──► /            static frontend (copied from its image by frontend_files)
                         ├─► /magpie      Magpie: users, groups, permissions
                         └─► /api, /geoserver ──► Twitcher (asks Magpie) ──► api / geoserver
geoserver ──WMS cascade──► geoserver-datastore ──► GeoTIFFs in /nas
api, geoserver, magpie, twitcher ──► PostGIS (databases gis, magpie, twitcher)
```

Always go through the wrapper `./geoimagenet-compose.sh`, never `docker compose` directly. It sources `env.local`, renders every tracked `*.template` file next to itself (for example `magpie.ini.template` becomes `magpie.ini`), runs `docker compose` with your arguments, and restarts nginx after `up`. Edit the `.template` files, never the rendered ones.

## Prerequisites

- Docker with the Compose v2 plugin (`docker compose version`).
- About 16 GB of RAM (each GeoServer is capped at 4 GB and 2 GB of heap) and disk for the imagery.
- Only for local builds (see the commented block in the override): the sibling repos, checked out on their fix branches. The images normally come from GHCR (`ghcr.io/sfoucher/`).

  ```
  ~/DEV/geoimagenet/
  ├── geoimagenet-compose/     this repo, branch feature/annotation-only
  ├── geoimagenet-api/         branch fix/build-2026
  └── geoimagenet-frontend/    branch fix/build-2026
  ```

## First installation

Run everything from this repo's folder.

**1. Local override.** It adds the datastore GeoServer (both GeoServers are the official `docker.osgeo.org/geoserver:3.0.2`, pinned by digest) and, locally, publishes the platform GeoServer on port 8600:

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
sudo mkdir -p /nas /data/db_gis_17 /data/geoserver_3/data_dir \
  /data/geoserver_datastore_3/data_dir /data/postgis_backups
sudo chown $USER /nas
```

On WSL2, keep these on the Linux filesystem, not under `/mnt/c`.

**5. Pull the images.** Name the services; never run a bare `pull` (see [Known traps](#known-traps)):

```bash
./geoimagenet-compose.sh pull api frontend_files
```

`frontend_files` is a one-shot service: at each `up` it copies the static frontend from its image into the `public` volume that nginx serves. (An image mount on nginx would be simpler, but Docker 29 can't mount an image referenced by digest: "file name too long".)

Until the GHCR packages are public (A4, see [Versioning](#versioning)), keep the `build:` lines in your override: `pull` fails with `denied` before that. `migrations` and `geoserver_setup` use the `api` image, so this covers them. The other images are pulled at the first `up`. To build from source instead, uncomment the local-development block in the override and run `./geoimagenet-compose.sh build api`, then `docker build -t geoimagenet-frontend:dev ../geoimagenet-frontend` and set `image: geoimagenet-frontend:dev` on `frontend_files`.

**6. Start the platform.** One command. Compose orders the start by health:
- PostGIS is healthy only once a real login on `gis` works. On an empty data directory its init script (`config/postgres/docker-entrypoint-initdb.d/10-databases.sh`) creates `gis`, `magpie` and `twitcher`, with PostGIS in `gis` only;
- `migrations` creates the schema and the taxonomies of `gis`;
- Magpie runs its database migration once before its workers start (`preload_app` in `magpie.ini`);
- then the API, Twitcher, the GeoServers and nginx start.

```bash
./geoimagenet-compose.sh up -d --wait
```

`--wait` returns once every service is healthy. The web interface is the static frontend copied by `frontend_files` (exits with 0): it answers within seconds. `migrations` also exits with 0. `geoserver_setup` belongs to the `setup` profile, so `up` doesn't start it: it runs when imagery is loaded.

**7. Check.** Open `https://${HOST_FQDN}` and accept the certificate warning if it is self-signed. Log in as `MAGPIE_ADMIN_USER` with `MAGPIE_ADMIN_PW`. The map stays empty until imagery is loaded.

## Loading imagery

The platform's `geoserver` does not read the image files. It cascades WMS from the **datastore GeoServer** (`geoserver-datastore`), which serves the GeoTIFFs in `/nas`. `geoserver_setup` configures both and registers each image in the database.

**1. Prepare each image.** Requirements (details in `../DEPLOYMENT_PLAN.md` §10.2):

- 8-bit, 4 bands in R, G, B, NIR order (or 3-band RGB).
- File name matching `Pleiades_<YYYYMMDD>_<BANDS>_50cm_<BITS>bits_AOI_<n>_<City>_<PROV>.tif`. `50cm` is fixed text in the pattern.
- A footprint shapefile named `..._trace.shp` (with `.shx`, `.dbf`, `.prj`). It is required: without it, `geoserver_setup` fails. Use CRIM's original traces when you have them; they match the 8-bit images even if their names say `16bits`.

Convert to a Cloud-Optimized GeoTIFF (tiles and overviews make GeoServer much faster) with an internal transparency mask, and, if there is no original trace, compute one. The source must declare its border pixels as NoData (`gdalinfo` shows `NoData Value=0`). `-mask 1` turns that NoData into an internal mask: GeoServer 2.15 drew NoData pixels opaque black through the RGB and NRG styles but honoured the mask; GeoServer 3 treats NoData correctly even without it, and the mask is kept anyway.

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

**3. Enable "full WMS" on the datastore (once per datastore, after the first publish).** Still needed on GeoServer 3 (checked: without it the datastore's tile cache answers the cascade with `GridAlignmentMismatchException`, and the map shows nothing). The cascade sends requests that are not aligned to the datastore's tile grid; with this setting they are rendered instead of refused. It must come after the first `geoserver_setup`: a fresh datastore only writes the `<layers/>` line this command edits during its first configuration (otherwise the command silently changes nothing; it should print `1`). The setting survives restarts.

```bash
docker exec geoserver-datastore sh -c 'f=/opt/geoserver_data/gwc/geowebcache.xml; grep -q "<fullWMS>" $f || sed -i "s|^  <layers/>$|  <layers/>\n  <fullWMS>true</fullWMS>|" $f; grep -c "<fullWMS>true" $f'
./geoimagenet-compose.sh up -d --force-recreate geoserver-datastore
```

If the map stays empty after a failed attempt (requests hang instead of failing), the platform GeoServer's connection pool to the datastore is exhausted by the failed requests: `curl -u admin:... -X POST http://localhost:8600/geoserver/rest/reset` on both GeoServers, or recreate `geoserver`.

**4. Restrict the platform GeoServer's WMS (once per data dir).** Logged-in users may read the whole `geoserver` service, and by default its `GetMap` also returns georeferenced GeoTIFF, KMZ, and images of any size, which amounts to a download of the imagery. The script limits `GetMap` to PNG and JPEG, caps the memory and rendering time of each request (which caps the image at about 2048×2048 px), disables dynamic styling (`SLD`, `SLD_BODY`), sets the imagery layers not queryable (no `GetFeatureInfo` pixel values) and disables WCS on both GeoServers. nginx also answers 404 on `/geoserver/web` and `/geoserver/rest`. Rerun it after each `geoserver_setup` that adds images (new layers are queryable by default).

```bash
./scripts/harden-wms.sh          # prints the new settings
```

**GeoServer image notes (3.0.2).**

- **Image:** official `docker.osgeo.org/geoserver:3.0.2` (Java 21, Tomcat 11, pgJDBC 42.7 with SCRAM, patched for CVE-2024-36401), pinned by index digest. To update, resolve the new digest with `docker buildx imagetools inspect docker.osgeo.org/geoserver:<tag>`, change it in `docker-compose.yml` and in the override, `pull` the two services by name. Data directories are not upgraded in place: a minor update keeps them, a major one deserves a rehearsal.
- **Data directories** are `/data/geoserver_3/data_dir` (platform) and `/data/geoserver_datastore_3/data_dir` (datastore), mounted at `/opt/geoserver_data`. Everything in them is rebuilt by `geoserver_setup` (plus steps 3 and 4), so after wiping one, redo steps 2 to 4 (the cached layers refill on demand).
- **Admin password:** unlike the old kartoza image, the official one rewrites the admin user and password from `GEOSERVER_ADMIN_USER` / `GEOSERVER_ADMIN_PASSWORD` at every start. Changing `GEOIMAGENET_API_GS_*_PASSWORD` in `env.local` and recreating the container is enough. The platform GeoServer's WMS stores (`PLEIADES_RGB`, `PLEIADES_NRG`) keep the datastore password they were created with: after changing the datastore password, delete those two stores (REST, `recurse=true`) and rerun `geoserver_setup`.
- **Heap:** measure on the VM (`docker stats` during a busy period) and consider 3G for the platform and 3G for the datastore, which renders the COGs. `EXTRA_JAVA_OPTS` (`-Xms1G -Xmx4G` platform, `-Xmx2G` datastore). It replaces the image's `-Xmx1g`, so keep `-Dorg.geotools.referencing.forceXY=true -Duser.timezone=GMT` in it. Raise the heap on hosts with more RAM, then `up -d --force-recreate geoserver geoserver-datastore`.
- **Startup:** healthy in about 30 s (Tomcat itself starts in 8 s).
- **NoData:** GeoServer 3 (JAI-EXT) honours `NoData Value=0` without the COG mask: an unmasked copy of the Sherbrooke scene rendered the same transparent borders. The `-mask 1` step above is kept (harmless, and independent of the server).

## Daily operation

```bash
./geoimagenet-compose.sh up -d --wait       # start, or bring everything back after a reboot
./geoimagenet-compose.sh down                # stop and remove the containers; all data is kept
./geoimagenet-compose.sh ps                  # status
./geoimagenet-compose.sh logs -f api         # follow one service
```

- **Stop with `down`, not `stop`.** `magpie`, `twitcher` and `nginx` have `restart: always`: after `stop`, Docker starts them again by itself at the next boot, leaving a half-started platform on port 443. `down` removes the containers but none of the data (databases, GeoServer configuration and imagery are in `/data` and `/nas`; `down` without `-v` keeps the volumes), and `up -d` recreates them identically. Verified on 2026-11-25.
- **After a reboot, run the `up -d --wait` line.** Both GeoServers have `restart: unless-stopped`, so they come back by themselves unless the platform was stopped with `down`, but nothing orders them after PostGIS: `up -d --wait` brings everything back in health order.
- **nginx and a recreated service.** nginx resolves `twitcher` and `magpie` once, at start, so a recreated container with a new address would give 502. Both cases are handled: `./geoimagenet-compose.sh restart twitcher` (or `magpie`) restarts nginx through `depends_on: restart: true`, and the wrapper restarts nginx after every `up`.
- **Never run a bare `pull`.** Name the images you mean to update. PostGIS is pinned by digest (`postgis/postgis:17-3.5@sha256:...`): never replace the digest by a freshly resolved one, because the PostGIS build under a tag changes (see [Known traps](#known-traps)).

## Deploying on a local Linux server

The same procedure on a dedicated Linux machine (physical or VM) on your network, used **on demand**: started for an annotation period, stopped in between. Not yet tried on such a server; the differences from the WSL setup are below.

**1. Hardware**

| Resource | Minimum | Recommended | Why |
|---|---|---|---|
| CPU | 4 cores | 8 cores | map tile rendering |
| RAM | 16 GB | 32 GB | 8–9 GB peak measured, plus the OS and the page cache for the imagery |
| System and `/data` | 150 GB SSD | 250 GB SSD | databases, tile cache, Docker images, dumps |
| `/nas` | 600 GB | 1 TB or more, on RAID 1 | 500 GB of imagery and room to grow |
| Network | fixed IP | fixed IP and a DNS name | `HOST_FQDN` is written into `/config.js` by nginx |

**2. System.** Ubuntu Server 24.04 LTS (or Debian 12). Install Docker Engine and the Compose plugin from Docker's repository. Mount the SSD at `/data` and the imagery disk at `/nas` in `/etc/fstab` (by UUID). Add 4 GB of swap, and limit the Docker logs in `/etc/docker/daemon.json`:

```json
{ "log-driver": "json-file", "log-opts": { "max-size": "50m", "max-file": "3" } }
```

**3. Access, host name and certificate.** Users' browsers call the URLs that nginx writes into `/config.js` for the frontend, so `HOST_FQDN` must be a name they can resolve, **never `localhost`**:

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
cd geoimagenet-compose
cp docker-compose.override.server.yml.example docker-compose.override.yml
cp env.local.example env.local && chmod 600 env.local
```

**Use the server override**, `docker-compose.override.server.yml.example`. It differs from the local one in two settings: GeoServer is not published on port 8600 (which would bypass Twitcher's access control), and Magpie SSL verification stays on. In `env.local`: new secrets (`openssl rand -hex 32`), the real `HOST_FQDN`, the certificate paths, and `TWITCHER_SSL_VERIFY=true`.

**6. Install** with [First installation](#first-installation), steps 4 to 7.

**7. Data: start fresh or migrate.**

- **Start fresh:** copy the imagery (`rsync -a --info=progress2 <source>/ <server>:/nas/`), then follow [Loading imagery](#loading-imagery).
- **Migrate an existing deployment**, keeping accounts, annotations and GeoServer configuration: on the old host, run a backup (`sudo ./scripts/pg-dump.sh`; on a host still on PostgreSQL 9.6, `docker exec postgis_backups /backups.sh`) and copy the dumps, `/nas` and `/data/geoserver_3/data_dir` and `/data/geoserver_datastore_3/data_dir` to the server with `rsync`. On the server, restore the dumps as in [Backups and restore](#backups-and-restore) instead of running installation step 6 on empty databases. The GeoServer admin password comes from `env.local` at every start.

**8. Run it on demand.**

```bash
cd ~/geoimagenet/geoimagenet-compose

# start an annotation period (about 30 seconds)
sudo apt update && sudo apt upgrade        # the machine is often off: update at each start
sudo certbot renew                         # Let's Encrypt only; does nothing if still valid
./geoimagenet-compose.sh up -d --wait

# end of the period
sudo ./scripts/pg-dump.sh                  # nothing dumps automatically: the server is often off
rsync -a /data/postgis_backups/ <backup-host>:geoimagenet-backups/
./geoimagenet-compose.sh down
```

- **Use `down` to stop**, not `stop`, or `magpie`, `twitcher` and `nginx` start again by themselves at the next boot.
- **Back up at the end of each period** and copy the dumps off the machine. RAID protects against a disk failure, not against a mistake or a lost server. Keep an offline copy of the imagery too.
- **Let's Encrypt certificates last 90 days** and only renew while the server is on, hence `certbot renew` at each start. A certificate from an internal CA, valid for years, avoids this.
- **Never run a bare `pull`.** The api and frontend images only change when you bump their tag (see [Versioning](#versioning)); pull them by name. The PostGIS image is pinned by digest and must stay so (see [Known traps](#known-traps)).

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

- **About 5 minutes of downtime**.
- **If the resize is refused**, delete the instance and create a new one from the same boot volume (`openstack server create --volume <boot-volume> --flavor <new-flavor> ...`), then attach the data volumes and the floating IP again. The IP and the DNS name don't change, so the certificate stays valid.
- **With more RAM, raise the GeoServer heap** (`EXTRA_JAVA_OPTS` in `docker-compose.yml` for `geoserver`, in the override for `geoserver-datastore`), then `up -d --force-recreate geoserver geoserver-datastore`.

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

`scripts/pg-dump.sh` dumps the three databases (`gis`, `magpie`, `twitcher`) with `pg_dump` run inside the `postgis` container, into `/data/postgis_backups/<year>/<Month>/geoimagenet_<db>.<dd-Month-YYYY>.dmp`. Each dump is written to a `.tmp` file, checked (not empty, not less than half of the previous one) and renamed, so a failed run never leaves a bad `.dmp`. The newest 14 dumps of each database are kept, so a long off period never leaves a single dump. There is no backup container and no scheduler: the platform runs on demand, so dump at the end of each period (see [Daily operation](#daily-operation)):

`/data/postgis_backups` is root-owned, so run it with sudo (`env.local` must be readable by root):

```bash
sudo ./scripts/pg-dump.sh
ls -l /data/postgis_backups/$(date +%Y)/$(date +%B)/
```

On a host that stays up, a line in root's crontab (`sudo crontab -e`) does the same each night:

```
0 23 * * *  cd /home/<user>/geoimagenet/geoimagenet-compose && ./scripts/pg-dump.sh >> /var/log/geoimagenet-dump.log 2>&1
```

The dumps stay on the same host. Copy them elsewhere (`rsync -a /data/postgis_backups/ <backup-host>:geoimagenet-backups/`) for a real backup. Roles are not dumped: the container environment recreates the role on an empty cluster.

**Restore** into an empty cluster (for example after losing the data directory, or to move to a new host):

```bash
./geoimagenet-compose.sh down
sudo rm -rf /data/db_gis_17/*        # empty data directory: the init script runs again
# starts PostGIS only. Do not start Magpie yet: it would migrate its empty database before the restore.
./geoimagenet-compose.sh up -d --wait postgis
./scripts/pg-restore.sh /data/postgis_backups/2026/November      # pick the dump folder
./geoimagenet-compose.sh run --rm migrations current              # must show (head)
./geoimagenet-compose.sh up -d --wait
```

`pg-restore.sh <dump-dir> [db...]` takes the newest dump of each database in the folder (`ls -t`), restores it with `pg_restore` as the superuser inside the container, prints the errors and **fails on anything outside a short allow-list**: the `public` schema and the `postgis` and `plpgsql` extensions already existing, `spatial_ref_sys` duplicate rows, and the legacy PostGIS 1.x functions (`asbinary`, `astext`, `setsrid`, ...) that a 9.6 dump carries and that nothing here calls. A 9.6 dump restores into 17, never the reverse. To check a restore, run `./scripts/db-fingerprint.sh > before.txt` (read-only: counts, sequence values and checksums, never data) before the move and diff it with the output after.

**Query the database** by hand (the `psql_gis` shell helper):

```bash
psql_gis() { set -a; . ./env.local; set +a; PGPASSWORD="$POSTGIS_PASSWORD" docker exec -it -e PGPASSWORD postgis psql -h localhost -U "$POSTGIS_USER" -d gis "$@"; }
psql_gis -c '\dx'      # plpgsql and postgis, plus fuzzystrmatch once the migrations ran
```

### Moving from PostgreSQL 9.6 to 17 (cut-over)

For a host that runs the old stack (`kartoza/postgis:9.6-2.4`, data in `/data/db_gis_data`). Same steps locally and on the VM. Allow about 15 minutes of downtime: the databases are small, the rest is checks. The old data directory is never touched again, so it is the rollback.

```bash
cd ~/geoimagenet/geoimagenet-compose
git describe --always               # must be fb5315d (the 9.6 stack with the patched 2.15 GeoServer)
git tag cut-0                       # the commit running today: the rollback point (local tag, not pushed)
df -h /data                         # space for a second copy of the databases
# 1. stop the writers (PostGIS stays up)
./geoimagenet-compose.sh stop api magpie twitcher geoserver geoserver-datastore nginx
# 2. the final state of the old stack: fingerprint, then the final dump, then the 9.6 copy
./scripts/db-fingerprint.sh > /tmp/fingerprint-96.txt
docker exec postgis_backups /backups.sh
sudo install -d /data/postgis_backups_pre-pg17                   # outside the 30-day cleanup of pg-dump.sh
for db in gis magpie twitcher; do
  ls -l "$(ls -t /data/postgis_backups/*/*/geoimagenet_$db.*.dmp | head -1)"   # check it is today's
done
for db in gis magpie twitcher; do
  sudo cp -p "$(ls -t /data/postgis_backups/*/*/geoimagenet_$db.*.dmp | head -1)" /data/postgis_backups_pre-pg17/
done
ls -l /data/postgis_backups_pre-pg17/
# 3. swap the stack
./geoimagenet-compose.sh down
# the named volume keeps its old device (/data/db_gis_data) even if the YAML changes: remove it
# (a bind volume: the host files are untouched) so it is recreated on /data/db_gis_17
docker volume rm geoimagenet-compose_postgis_data
sudo install -d /data/db_gis_17
# the VM first needs these commits (filtered branch + bundle) before it can check them out
git checkout 32a2178                # PostgreSQL 17 with the 2.15 GeoServer (pgJDBC 42.2.29); the GeoServer 3 move is the next runbook
# GeoServer image with pgJDBC 42.2.29 (SCRAM): at 32a2178, use that commit's override example
# (it builds geoimagenet-geoserver:2.15.0-cve-2024-36401-pgjdbc42229)
./geoimagenet-compose.sh build geoserver geoserver-datastore
./geoimagenet-compose.sh pull postgis
./geoimagenet-compose.sh up -d --wait postgis                     # init script creates gis, magpie, twitcher
# 4. restore and compare
./scripts/pg-restore.sh /data/postgis_backups_pre-pg17              # the final 9.6 dumps
./scripts/db-fingerprint.sh | diff /tmp/fingerprint-96.txt - && echo IDENTICAL
./geoimagenet-compose.sh run --rm migrations current              # must show (head)
# 5. start everything and check
./geoimagenet-compose.sh up -d --wait
sudo ./scripts/pg-dump.sh           # first dump on 17
ls /data/db_gis_data >/dev/null && echo "old data directory intact"
git tag cut-1                       # PostgreSQL 17 running: the starting point of the GeoServer runbook
```

Checks: the web interface loads, you can log in as `MAGPIE_ADMIN_USER`, an annotation can be created and deleted, the imagery renders. Also an anonymous WFS request, which exercises GeoServer's JDBC login to PostgreSQL 17 (use `-k` with a self-signed certificate):

```bash
curl -sk "https://<host>/geoserver/wfs?service=WFS&version=1.1.0&request=GetFeature&typeName=GeoImageNet:annotation&maxFeatures=1&outputFormat=application/json" | head -c 300
```

It must return a FeatureCollection, not an exception. Do the same for a footprint layer (`PLEIADES_CONTOURS:...`, with a logged-in session cookie if anonymous access is not allowed). `docker exec postgis psql -U $POSTGIS_USER -d gis -Atc 'select version()'` (with `PGPASSWORD`) shows 17.x.

**Rollback** (data written since step 5 is lost, so decide before users come back):

```bash
./geoimagenet-compose.sh down
docker volume rm geoimagenet-compose_postgis_data   # same reason: back to the old device
git checkout cut-0
./geoimagenet-compose.sh up -d --wait
```

Keep `/data/db_gis_data`, `/data/postgis_backups_pre-pg17`, the `kartoza/*` images and the tag `cut-0` until a few periods have passed on 17, then delete the old directory.

### Moving GeoServer from 2.15 to 3.0.2 (cut-over)

For a host that runs the 2.15 GeoServers (`geoimagenet-geoserver:2.15.0-...`, data in `/data/geoserver/data_dir` and `/data/geoserver_datastore/data_dir`). Same steps locally and on the VM. Downtime is the setup time: a few minutes with one image; with about 40 images allow 30 to 60 minutes (the datastore is rebuilt from the files, nothing is copied). The 2.15 directories are never mounted by the new containers: they are the rollback. Needs the api image that contains the GeoServer 3 fixes (`geoserver_setup` fails on 3.0 with an older one: "No endpoint POST /geoserver/rest/namespaces/.").

```bash
cd ~/geoimagenet/geoimagenet-compose
git describe --always                # must be the PostgreSQL 17 commit 32a2178 (tag cut-1); if not, tag it: git tag cut-1
# keep the 2.15 image for the rollback (the new override no longer builds it)
sudo sh -c 'docker save geoimagenet-geoserver:2.15.0-cve-2024-36401-pgjdbc42229 | gzip > /data/geoserver-2.15-image.tar.gz'
# 1. stop the GeoServers
./geoimagenet-compose.sh stop geoserver geoserver-datastore nginx
# 2. new, empty data directories
sudo install -d /data/geoserver_3/data_dir /data/geoserver_datastore_3/data_dir
# 3. new commit, new images; re-copy the override example (the GeoServer blocks changed)
git checkout <the GeoServer 3 commit>
cp docker-compose.override.yml docker-compose.override.yml.bak-pre-gs3
cp docker-compose.override.server.yml.example docker-compose.override.yml   # servers; locally: docker-compose.override.yml.example
# put back the local settings of the old override (api dev image lines, ...) then:
./geoimagenet-compose.sh pull geoserver geoserver-datastore geoserver_setup
./geoimagenet-compose.sh up -d --wait geoserver geoserver-datastore      # about 30 s each
# 4. configure both GeoServers from the imagery
./geoimagenet-compose.sh run --rm geoserver_setup --setup-datastore
#    Many images: the mirror may fail layers with "Could not find layer ... in the server capabilities document".
#    Reset both and rerun until it ends without a traceback:
set -a; . ./env.local; set +a
docker exec geoserver curl -sf -u "admin:$GEOIMAGENET_API_GS_MIRROR_PASSWORD" -X POST http://localhost:8080/geoserver/rest/reset
docker exec geoserver-datastore curl -sf -u "admin:$GEOIMAGENET_API_GS_DATASTORE_PASSWORD" -X POST http://localhost:8080/geoserver/rest/reset
# 5. full WMS on the datastore (must print 1), then recreate it, then the restrictions
docker exec geoserver-datastore sh -c 'f=/opt/geoserver_data/gwc/geowebcache.xml; grep -q "<fullWMS>" $f || sed -i "s|^  <layers/>$|  <layers/>\n  <fullWMS>true</fullWMS>|" $f; grep -c "<fullWMS>true" $f'
./geoimagenet-compose.sh up -d --force-recreate --wait geoserver-datastore
./scripts/harden-wms.sh
./geoimagenet-compose.sh up -d --wait          # restarts nginx too
```

Checks (the G acceptance block of the plan): map loads RGB and NRG imagery at pixel ratio 1 and 2, borders transparent, the annotation thumbnails render, a new annotation shows up; as a logged-in user GeoTIFF, KMZ, PDF, `SLD_BODY`, `GetFeatureInfo` and an 8192 px PNG are refused (GeoServer answers 200 with a `ServiceException`: check the content type is not `image/*`); anonymous: imagery 401, WMTS capabilities 401, WCS answers an exception, WFS on `GeoImageNet:annotation` 200, `/geoserver/web/` and `/geoserver/rest/...` 404; the mirror's `GetCapabilities` has the same layer names and keywords as before; a second `geoserver_setup --setup-datastore` ends without errors, then rerun `harden-wms.sh`. When all is well, `git tag cut-2` (GeoServer 3 running).

**Rollback:** `./geoimagenet-compose.sh down`, `git checkout cut-1`, restore the old override (`cp docker-compose.override.yml.bak-pre-gs3 docker-compose.override.yml`), `gunzip -c /data/geoserver-2.15-image.tar.gz | docker load`, `./geoimagenet-compose.sh up -d --wait`. The old directories were never touched; annotations are in PostgreSQL, so nothing is lost. Delete `/data/geoserver`, `/data/geoserver_datastore` and the image archive once a few periods have passed.

## Known traps

| Symptom | Cause and fix |
|---|---|
| Wrapper error "Required variable X is not set" | Fill in `X` in `env.local`. |
| `password authentication failed` right after starting PostGIS for the first time | PostGIS was still in its first-run setup. Its healthcheck waits for a real login on `gis`; start with `up -d --wait`. |
| After a PostGIS image change, `could not access file "$libdir/postgis-..."` | The image is pinned by digest because a tag can be re-pushed with another PostGIS build. Keep the `@sha256:` pin, pull only the images you update, and restore from a dump (Backups and restore) if it happened. |
| PostGIS password or user changed in `env.local`, login still fails | The official image applies `POSTGRES_USER` and `POSTGRES_PASSWORD` once, when the data directory is empty. Change the role's password in PostgreSQL (`ALTER ROLE`) or restore into a new directory. |
| A client says `authentication method 10 not supported` | It uses a libpq older than 10 (SCRAM). Checked: the api (libpq 15), Magpie and Twitcher (11) are fine, and the official GeoServer 3.0.2 image has pgJDBC 42.7.x. If another client cannot, set `POSTGRES_HOST_AUTH_METHOD=md5` and `command: postgres -c password_encryption=md5` on `postgis` **before the first init** (the password is hashed when the role is created); it applies to every client. |
| Magpie logs `duplicate key` or `expected to match one row` on first start | It started with several workers. Drop and re-create the `magpie` database, then run the single-worker init. |
| 502 from nginx after restarting a service | `./geoimagenet-compose.sh restart nginx`. Shouldn't happen with `restart` or `up` (see Daily operation). |
| GeoServer container healthy but the map is empty, GetMap requests hang | The datastore's `fullWMS` is off (step 3) or its connection pool is exhausted: see step 3. |
| Every call to a GeoServer container returns 400 | Its name contains `_`; Tomcat rejects such host names. Use `-`. |
| Map tiles fail with "Content type is required" | "Full WMS" is off on the datastore (Loading imagery, step 3). |
| Users get "There was a problem connecting to magpie" | The API must reach Magpie at `http://magpie:2001` (`GEOIMAGENET_API_MAGPIE_URL`), never through `https://${HOST_FQDN}`. |
| Annotations or imagery visible without login | Check `config/magpie/permissions.cfg`. Keep the Twitcher ACL cache disabled: it is incompatible with route-level permissions in Magpie 1.6. |

## Versioning

We use bump2version: `pip install bump2version`. Bump the version with `make VERSION=<target_tag> bump` (`make VERSION=<target_tag> dry bump` to preview).

### Releasing the api and frontend images

The images are built by GitHub Actions in the forks (`sfoucher/geoimagenet-api` and `-frontend`, branch `fix/build-2026`) and published to `ghcr.io/sfoucher/geoimagenet-api` and `-frontend`. A branch push builds without publishing, to catch breakage.

1. In the fork, bump the version in the source (`geoimagenet_api/__about__.py`, or `VERSION` and `package.json`) and commit.
2. Tag `vX.Y.Z-gin.N` and push the tag. `N` counts the fork's releases of the same upstream version `X.Y.Z` (the images are built from `fix/build-2026`, not from CRIM's tag). `v1.4.2-gin.1` publishes `ghcr.io/sfoucher/geoimagenet-api:1.4.2-gin.1` (and `:sha-<short>`). The Action builds, runs a smoke test, then pushes that same image. Wait for it to turn green.
3. In `docker-compose.yml`, change the tag and, once digests are in use, the digest (`docker buildx imagetools inspect ghcr.io/sfoucher/geoimagenet-api:X.Y.Z`).
4. Pull only what changed, then recreate it: `./geoimagenet-compose.sh pull api` then `./geoimagenet-compose.sh up -d api` (`migrations` runs again with it). Name the service every time; never run a bare `pull`. For the frontend: `./geoimagenet-compose.sh pull frontend_files` then `./geoimagenet-compose.sh up -d --wait`. The frontend image holds no URL: `/config.js` is generated by nginx from `HOST_FQDN` and `CONTACT_EMAIL`.
   - **Once, on a host upgraded from a version that still had the `frontend` service:** `./geoimagenet-compose.sh up -d --wait --remove-orphans` removes the old `frontend` container, then `docker volume rm geoimagenet-compose_dist` removes its build volume (`--remove-orphans` doesn't remove volumes).
5. Record the release in this repo: `make VERSION=<x.y.z> bump` (bump2version keeps the version strings in sync).

**Package visibility (once per package, GitHub web UI).** After the first successful run, open each package (Packages, then Package settings): set the visibility to Public and link it to its repository. Until this succeeds, keep the `build:` lines in your override. Check without a login:

```bash
docker logout ghcr.io; docker pull ghcr.io/sfoucher/geoimagenet-api:1.4.2-gin.1
```

The images hold no secret and no imagery. The workflows use only the automatic `GITHUB_TOKEN`.

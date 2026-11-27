#!/bin/bash
# Restrict what the GeoServers answer. Run after geoserver_setup; the settings persist in the data dirs.
# Platform GeoServer (behind Twitcher, logged-in users have "read" on all of it):
#   - GetMap only as PNG or JPEG (no GeoTIFF, KMZ, PDF...), memory/time caps that bound the image
#     size (about 2048x2048 px), no dynamic styling (SLD, SLD_BODY, external STYLES);
#   - the imagery layers are not queryable (no GetFeatureInfo pixel values);
#   - WCS disabled.
# Datastore GeoServer (reached by the platform GeoServer only): WCS disabled.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./env.local; set +a
MEM_KB=${WMS_MAX_REQUEST_MEMORY_KB:-17000}   # 2048*2048*4 bytes = 16384 KB
TIME_S=${WMS_MAX_RENDERING_TIME_S:-60}
U=http://localhost:8080/geoserver/rest
gs()  { docker exec -i geoserver curl -sf -u "admin:$GEOIMAGENET_API_GS_MIRROR_PASSWORD" "$@"; }
gsd() { docker exec -i geoserver-datastore curl -sf -u "admin:$GEOIMAGENET_API_GS_DATASTORE_PASSWORD" "$@"; }

gs $U/services/wms/settings.xml | python3 -c '
import sys, re
x, mem, t = sys.stdin.read(), sys.argv[1], sys.argv[2]
x = re.sub(r"<getMapMimeTypeCheckingEnabled>\w+<", "<getMapMimeTypeCheckingEnabled>true<", x)
x = re.sub(r"\s*<getMapMimeTypes>.*?</getMapMimeTypes>|\s*<getMapMimeTypes/>", "", x, flags=re.S)
x = x.replace("<getMapMimeTypeCheckingEnabled>true</getMapMimeTypeCheckingEnabled>",
  "<getMapMimeTypeCheckingEnabled>true</getMapMimeTypeCheckingEnabled>\n  <getMapMimeTypes>\n    <string>image/png</string>\n    <string>image/jpeg</string>\n  </getMapMimeTypes>")
x = re.sub(r"<dynamicStylingDisabled>\w+<", "<dynamicStylingDisabled>true<", x)
x = re.sub(r"<maxRequestMemory>\d+<", "<maxRequestMemory>%s<" % mem, x)
x = re.sub(r"<maxRenderingTime>\d+<", "<maxRenderingTime>%s<" % t, x)
sys.stdout.write(x)' "$MEM_KB" "$TIME_S" \
| gs -X PUT -H 'Content-Type: application/xml' --data-binary @- $U/services/wms/settings
gs $U/services/wms/settings.xml | grep -E 'getMapMimeTypeCheckingEnabled|<string>image|dynamicStylingDisabled|maxRequestMemory|maxRenderingTime'

# imagery layers (the cascaded PLEIADES_* ones) are not queryable
for l in $(gs $U/layers.json | python3 -c 'import json,sys; print(*[x["name"] for x in json.load(sys.stdin)["layers"]["layer"] if x["name"].startswith("PLEIADES_")])'); do
  gs -X PUT -H 'Content-Type: application/json' -d '{"layer":{"queryable":false}}' "$U/layers/$l.json"
done
echo "imagery layers queryable=false: $(gs $U/layers.json | python3 -c 'import json,sys; print(sum(x["name"].startswith("PLEIADES_") for x in json.load(sys.stdin)["layers"]["layer"]))') layer(s)"

gs  -X PUT -H 'Content-Type: application/json' -d '{"wcs":{"enabled":false}}' $U/services/wcs/settings.json
gsd -X PUT -H 'Content-Type: application/json' -d '{"wcs":{"enabled":false}}' $U/services/wcs/settings.json
echo "WCS enabled (mirror, datastore): $(gs $U/services/wcs/settings.json | grep -o '"enabled":[a-z]*' | head -1), $(gsd $U/services/wcs/settings.json | grep -o '"enabled":[a-z]*' | head -1)"

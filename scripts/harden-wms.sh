#!/bin/bash
# Restrict what the platform GeoServer (the one behind Twitcher) answers to logged-in users:
# GetMap only as PNG or JPEG (no GeoTIFF, KMZ, PDF...), and a memory/time cap that bounds
# the image size (about 2048x2048 px). Run after geoserver_setup; settings persist in the data dir.
set -euo pipefail
cd "$(dirname "$0")/.."
set -a; . ./env.local; set +a
MEM_KB=${WMS_MAX_REQUEST_MEMORY_KB:-17000}   # 2048*2048*4 bytes = 16384 KB
TIME_S=${WMS_MAX_RENDERING_TIME_S:-60}
gs() { docker exec -i geoserver curl -sf -u "admin:$GEOIMAGENET_API_GS_MIRROR_PASSWORD" "$@"; }
gs http://localhost:8080/geoserver/rest/services/wms/settings.xml | python3 -c '
import sys, re
x, mem, t = sys.stdin.read(), sys.argv[1], sys.argv[2]
x = re.sub(r"<getMapMimeTypeCheckingEnabled>\w+<", "<getMapMimeTypeCheckingEnabled>true<", x)
x = re.sub(r"\s*<getMapMimeTypes>.*?</getMapMimeTypes>|\s*<getMapMimeTypes/>", "", x, flags=re.S)
x = x.replace("<getMapMimeTypeCheckingEnabled>true</getMapMimeTypeCheckingEnabled>",
  "<getMapMimeTypeCheckingEnabled>true</getMapMimeTypeCheckingEnabled>\n  <getMapMimeTypes>\n    <string>image/png</string>\n    <string>image/jpeg</string>\n  </getMapMimeTypes>")
x = re.sub(r"<maxRequestMemory>\d+<", "<maxRequestMemory>%s<" % mem, x)
x = re.sub(r"<maxRenderingTime>\d+<", "<maxRenderingTime>%s<" % t, x)
sys.stdout.write(x)' "$MEM_KB" "$TIME_S" \
| gs -X PUT -H 'Content-Type: application/xml' --data-binary @- http://localhost:8080/geoserver/rest/services/wms/settings
gs http://localhost:8080/geoserver/rest/services/wms/settings.xml | grep -E 'getMapMimeTypeCheckingEnabled|<string>image|maxRequestMemory|maxRenderingTime'

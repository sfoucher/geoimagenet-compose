# kartoza/geoserver 2.15.0 (no longer patched), with two fixes. Remove this image when step 2
# moves to a maintained GeoServer.
FROM kartoza/geoserver:2.15.0@sha256:6e04cd515da846d0791ccaad0c69cec9a450424fee90481ab367d9147e0a58dc
ARG LIB=/usr/local/tomcat/webapps/geoserver/WEB-INF/lib
# 1. CVE-2024-36401 (remote code execution through OGC filter/property expressions in WFS, WMS
#    and WPS): the official workaround for versions that get no fix is to remove gt-complex.
#    It disables app-schema features, and the CSW extension that depends on it (its jars must
#    go too, or GeoServer fails to start): the platform uses neither.
# 2. The image ships two sqlite-jdbc versions. Tomcat's annotation scan then sees a cyclic class
#    hierarchy across the two jars and, depending on scan order, fails with StackOverflowError:
#    GeoServer answers 404 after some restarts. Keep the newer jar and don't scan it.
RUN rm $LIB/gt-complex-*.jar $LIB/gs-csw-*.jar $LIB/gs-web-csw-*.jar $LIB/sqlite-jdbc-3.23.1.jar \
 && sed -i 's/^tomcat.util.scan.StandardJarScanFilter.jarsToSkip=\\$/&\nsqlite-jdbc-*.jar,\\/' /usr/local/tomcat/conf/catalina.properties \
 && grep -q '^sqlite-jdbc-\*.jar,' /usr/local/tomcat/conf/catalina.properties

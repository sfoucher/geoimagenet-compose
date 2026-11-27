# kartoza/geoserver 2.15.0 (no longer patched), with three fixes. Remove this image when step 2
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
# 3. PostgreSQL 17 stores passwords as SCRAM-SHA-256. The shipped pgJDBC 42.1.1 fails with "The
#    authentication type 10 is not supported" (SCRAM needs 42.2.0 or later), so the annotation
#    PostGIS store could not connect. 42.2.29 is the last 42.2 release: same API, Java 8.
ADD --checksum=sha256:4c5d4528527354b2e594f458f0807e710f4d5683491179d2580f3d5ae5e7477c \
    https://repo1.maven.org/maven2/org/postgresql/postgresql/42.2.29/postgresql-42.2.29.jar /tmp/
RUN rm $LIB/postgresql-42.1.1.jar && mv /tmp/postgresql-42.2.29.jar $LIB/

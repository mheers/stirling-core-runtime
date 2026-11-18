# syntax=docker/dockerfile:1
#
# The MIT core PDF runtime.
#
# This image is the upstream `Stirling-PDF-server.jar` v3.3.0 — the MIT core
# release, no proprietary or SaaS classes, no licence check — plus the free
# tooling the v1 verbs need around it. It is not a source build: there is no
# Gradle and no Node here, and the jar is reused exactly as upstream published
# it. The pinned sha256 is checked at build time, so a different jar cannot
# produce this image.
#
# No Ghostscript. It is AGPL and excluded from this runtime by the licence
# floor; a verb that needs it is disabled by the engine's own
# external-dependency probe and answers its own "not available" answer. Repair
# falls back to qpdf, compress is qpdf plus pure-Java image compression, and
# PDF/A uses the jar's own `stirling-office-convert-pdfa` library (LibreOffice
# under the hood) instead of `gs`.
#
# Build: `./build-image.sh` from this directory. It downloads the pinned jar
# into the build context and runs `docker build`; a plain `docker build` works
# once `app.jar` is in place. The build needs no network beyond the apt mirror.
#
# Runtime: the image starts with no egress (`--network none`), no login, no
# port on the host, and no volume. Everything it writes is a container-local
# scratch path (see README.md).

# The base is pinned by digest, not by tag: a tag would let a later push change
# the JVM under a rebuild.
FROM eclipse-temurin:25-jre-noble@sha256:e3b6f7887a50f20d8f07abf279d8a81a5953fb398a9555bd9edd56b9bd15968c

ARG STIRLING_VERSION=3.3.0
ARG JAR_SHA256=5cb59682f93bd7d48312d36a87585ef2e8ca9ddfa64bc210dea6bd882925557c

LABEL org.opencontainers.image.title="stirling-core-runtime" \
      org.opencontainers.image.description="Stirling-PDF-server.jar ${STIRLING_VERSION} (MIT core) with LibreOffice, qpdf and poppler; no Ghostscript" \
      org.opencontainers.image.version="${STIRLING_VERSION}" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.source="https://github.com/mheers/stirling-core-runtime"

ENV DEBIAN_FRONTEND=noninteractive \
    STIRLING_VERSION=${STIRLING_VERSION} \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    HOME=/home/stirlingpdfuser \
    STIRLING_TEMPFILES_DIRECTORY=/tmp/stirling-pdf \
    TMPDIR=/tmp/stirling-pdf \
    # LibreOffice renders headless through its null VCL plugin: no X server, no
    # Xvfb, no display socket. These are upstream's own headless settings and
    # keep soffice's RSS down.
    SAL_USE_VCLPLUGIN=svp \
    SAL_DISABLE_PRINTERLIST=1 \
    OOO_FORCE_DESKTOP=none \
    MALLOC_ARENA_MAX=2 \
    # No telemetry and no outbound capability in the artefact itself, so a
    # deployment that forgot the switches is still silent: analytics, PostHog,
    # the Scarf pixel, the update check and URL-to-PDF (the one verb that would
    # fetch). The example deployment sets the same four; this is defence in
    # depth, not a substitute for its network boundary.
    SYSTEM_ENABLEANALYTICS=false \
    SYSTEM_ENABLEPOSTHOG=false \
    SYSTEM_ENABLESCARF=false \
    SYSTEM_SHOWUPDATE=false \
    SYSTEM_ENABLEURLTOPDF=false \
    JAVA_TOOL_OPTIONS="-XX:MaxRAMPercentage=70 -XX:+ExitOnOutOfMemoryError -Dfile.encoding=UTF-8 -Djava.awt.headless=true"

# The runtime packages, and nothing that would pull a licence we exclude:
#   libreoffice-writer-nogui / libreoffice-draw-nogui
#                         docx→pdf, pptx/xlsx→pdf and the PDF/A path's own
#                         LibreOffice leg; the -nogui split leaves out the
#                         desktop shell and the Base database frontend.
#   qpdf                  repair (the fallback after a missing gs) and the
#                         compression/linearisation pass.
#   poppler-utils         pdftohtml/pdfimages text and image extraction.
#   fonts-dejavu-core, fonts-liberation2
#                         the metric-compatible set LibreOffice and PDFBox
#                         substitute for Calibri/Arial/Times in real contracts.
#   tini                  PID 1 that reaps zombies and forwards signals.
#   curl                  the healthcheck; no shell-level telemetry.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        tini \
        qpdf \
        poppler-utils \
        libreoffice-writer-nogui \
        libreoffice-draw-nogui \
        fonts-dejavu-core \
        fonts-liberation2 \
 && rm -rf /var/lib/apt/lists/* \
 && groupadd --gid 1001 stirlingpdfgroup \
 && useradd --uid 1001 --gid 1001 --create-home \
        --home-dir /home/stirlingpdfuser --shell /usr/sbin/nologin stirlingpdfuser \
 && mkdir -p /app /configs /customFiles /logs /pipeline /storage /tmp/stirling-pdf \
 && ln -s /configs /app/configs \
 && ln -s /customFiles /app/customFiles \
 && ln -s /logs /app/logs \
 && ln -s /pipeline /app/pipeline \
 && ln -s /storage /app/storage \
 && chown -R 1001:1001 \
        /app /configs /customFiles /logs /pipeline /storage /tmp/stirling-pdf \
        /home/stirlingpdfuser

WORKDIR /app

# The artefact, checked byte-for-byte. `app.jar` is the upstream release asset
# `Stirling-PDF-server.jar` v3.3.0, downloaded by build-image.sh; the COPY
# before the checksum keeps the check out of the apt layer's cache.
COPY app.jar /app/app.jar
RUN echo "${JAR_SHA256}  /app/app.jar" | sha256sum -c - \
 && chown 1001:1001 /app/app.jar

COPY --chmod=0755 entrypoint.sh /usr/local/bin/pdf-mit-core

USER 1001:1001

# No LOGIN, no volume, no egress: the boundary is the compose network, not this
# image. The app writes its H2 database, settings and scratch files below
# /configs, /logs and /tmp/stirling-pdf; a deployment mounts those as tmpfs so
# a restart has no history.
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=15s --start-period=120s --retries=5 \
  CMD curl -fsS --max-time 10 http://127.0.0.1:8080/api/v1/info/status || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/pdf-mit-core"]

#!/bin/sh
# PID's child of tini for the MIT core PDF runtime.
#
# There is deliberately almost nothing here. Upstream's own init script is a
# 58 KB supervisor that builds an AOT cache, starts a unoserver pool, an AI
# engine and a diagnostics helper; none of that is in this image. The jar is
# started directly, with the JVM options the image sets and the scratch paths
# a read-only root needs, and it stops when its process stops.
set -eu

# The application writes the H2 database and settings below /configs (it
# resolves `./configs` from WORKDIR /app through a symlink), its logs below
# /logs, and unpacks libpdfium.so into the temp directory. In the compose
# deployment these are tmpfs mounts; in a bare `docker run` they are the
# image's own writable layer. `|| true` keeps a read-only-root deployment
# working when the mounts are already there.
mkdir -p \
    "${STIRLING_TEMPFILES_DIRECTORY:-/tmp/stirling-pdf}" \
    /configs /customFiles /logs /pipeline /storage 2>/dev/null || true

# JAVA_TOOL_OPTIONS is set in the image and read by every JVM; JAVA_OPTS is the
# operator's override, appended after it so a deployment can raise the heap
# without rebuilding. `set --` keeps an unset or empty JAVA_OPTS harmless.
# shellcheck disable=SC2086 # the split is the point: JAVA_OPTS is a word list
set -- ${JAVA_OPTS:-} -jar /app/app.jar "$@"

echo "pdf-mit-core: starting $STIRLING_VERSION jar on port ${SERVER_PORT:-8080}" >&2
exec java "$@"

#!/usr/bin/env bash
# Build the MIT core PDF runtime image from the pinned upstream jar.
#
# The jar is a release asset, not a repository file: a 222 MB binary does not
# belong in git. This script downloads it once into the build context, checks
# the pinned sha256, and then runs a plain `docker build`. A jar that does not
# match the pin is never built: the Dockerfile checks the digest again inside
# the build, so the two checks cannot disagree.
#
# There is no other build system here — no Gradle, no Node, no source build.
#
# Usage: build-image.sh [TAG]
# Exit: 0 image built, 1 the build failed, 2 a prerequisite is missing.
#
# Leak-proof by construction: this script starts no load, no loop and no
# background child. A download that is interrupted leaves `app.jar.part`, not a
# process, and the next run replaces it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="3.3.0"
SHA256="5cb59682f93bd7d48312d36a87585ef2e8ca9ddfa64bc210dea6bd882925557c"
URL="https://github.com/Stirling-Tools/Stirling-PDF/releases/download/v${VERSION}/Stirling-PDF-server.jar"
TAG="${1:-${STIRLING_CORE_RUNTIME_TAG:-stirling-core-runtime:dev}}"
JAR="$DIR/app.jar"
PART="$JAR.part"

fail() { printf 'FAIL  %s\n' "$*" >&2; exit 2; }

command -v docker >/dev/null 2>&1 || fail "docker is not on PATH"
command -v curl >/dev/null 2>&1 || fail "curl is not on PATH"
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum is not on PATH"
docker info >/dev/null 2>&1 || fail "the docker daemon is not reachable"

jar_ok() {
  [ -f "$JAR" ] && printf '%s  %s\n' "$SHA256" "$JAR" | sha256sum -c - >/dev/null 2>&1
}

if jar_ok; then
  printf 'jar      %s (pinned sha256 verified)\n' "$JAR"
else
  # A previous run's partial file is replaced, never resumed: a resumed file
  # with a stale first byte is a corrupted jar that the digest would catch only
  # after another 222 MB.
  rm -f "$PART"
  printf 'fetch    %s\n' "$URL"
  curl -fsSL --retry 3 --retry-delay 2 --max-time 900 -o "$PART" "$URL" \
    || fail "download failed: $URL"
  printf '%s  %s\n' "$SHA256" "$PART" | sha256sum -c - \
    || { rm -f "$PART"; fail "the downloaded jar is not the pinned artefact"; }
  mv -f "$PART" "$JAR"
  printf 'jar      %s (downloaded and verified)\n' "$JAR"
fi

printf 'build    %s\n' "$TAG"
docker build \
  --build-arg "STIRLING_VERSION=$VERSION" \
  --build-arg "JAR_SHA256=$SHA256" \
  -t "$TAG" \
  "$DIR"

printf 'image    %s\n' "$(docker image inspect "$TAG" --format '{{.Id}}')"
printf 'size     %s\n' "$(docker image inspect "$TAG" --format '{{.Size}}') bytes"
printf 'PASS     %s built from jar sha256 %s\n' "$TAG" "$SHA256"

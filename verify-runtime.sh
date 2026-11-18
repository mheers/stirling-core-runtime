#!/usr/bin/env bash
# The runtime proof of the MIT core PDF runtime.
#
# What it proves, against the image build-image.sh produced:
#
#   1. the image is the pinned artefact: the jar inside it has the pinned
#      sha256, the log says "Without additional features in jar", and `gs` is
#      absent (the licence floor);
#   2. it starts with NO network (`--network none`), as a non-root user, on a
#      read-only root with the example deployment's tmpfs mounts and ceilings,
#      and answers `GET /api/v1/info/status` with 200;
#   3. the enabled endpoint matrix — pdf-to-pdfa, compress, docx→pdf and a
#      poppler text extraction — produces checked output on a one-page and a
#      fifty-page fixture (page count, text, size), not only 200s;
#   4. every Ghostscript-dependent endpoint answers the product's own 403, not
#      a 500 and not an empty file;
#   5. every compose file named on the command line keeps `internal: true` and
#      publishes no port (the default is compose.example.yaml beside this
#      script);
#   6. sizes and times: image size, cold start, per-endpoint duration.
#
# Every path is resolved from this script's own directory (`DIR`), so the tree
# can be copied to a repository root and run unchanged.
#
# Leak-proof by construction, not by `trap … EXIT`. The only long-lived process
# is the named container this script starts; its id is recorded under $STATE as
# it starts, a previous invocation's container is removed at the START of the
# next one, and the end asserts that nothing with the label remains. There is
# no background child, no busy loop and no burner: the load is one JVM bounded
# to 2 CPUs and 4 GiB, exactly the deployment's ceiling.
#
# Usage: verify-runtime.sh [--tag TAG] [--compose FILE]...
# Exit: 0 every assertion passed, 1 an assertion failed, 2 a prerequisite is
# missing (no Docker daemon, no image, no fixture, no compose file). It never
# pulls.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TAG="${STIRLING_CORE_RUNTIME_TAG:-stirling-core-runtime:dev}"
NAME="${STIRLING_CORE_RUNTIME_PROOF_NAME:-stirling-core-runtime-proof}"
LABEL="io.github.mheers.stirling-core-runtime.proof=true"
STATE="${STIRLING_CORE_RUNTIME_PROOF_STATE:-${TMPDIR:-/tmp}/stirling-core-runtime/verify}"
JAR_SHA256="5cb59682f93bd7d48312d36a87585ef2e8ca9ddfa64bc210dea6bd882925557c"
MATRIX="$DIR/verify/endpoint-matrix.sh"
FIXTURES=(
  "$DIR/fixtures/base-1p.pdf"
  "$DIR/fixtures/base-50p.pdf"
  "$DIR/fixtures/office-1p.docx"
  "$DIR/fixtures/office-50p.docx"
)
COMPOSE_FILES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tag) TAG="${2:?--tag needs a value}"; shift 2 ;;
    --compose) COMPOSE_FILES+=("${2:?--compose needs a value}"); shift 2 ;;
    -h|--help)
      printf 'usage: %s [--tag TAG] [--compose FILE]...\n' "$0"
      printf '  --tag      the image to prove (default %s)\n' "$TAG"
      printf '  --compose  a compose file whose boundary is checked (repeatable;\n'
      printf '             default %s/compose.example.yaml)\n' "$DIR"
      exit 0 ;;
    *) printf 'FAIL  unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
if [ "${#COMPOSE_FILES[@]}" -eq 0 ]; then
  COMPOSE_FILES=("$DIR/compose.example.yaml")
fi

failures=0
pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

mkdir -p "$STATE"
ID_FILE="$STATE/container-id"

# reap — remove this script's own container, whatever a previous invocation
# left, before starting a new one. This is the `finally` a SIGKILLed shell
# cannot run; the trap below is a courtesy, not the guarantee.
reap() {
  if [ -f "$ID_FILE" ]; then
    docker rm -f "$(cat "$ID_FILE")" >/dev/null 2>&1 || true
    rm -f "$ID_FILE"
  fi
  ids="$(docker ps -aq --filter "label=$LABEL" 2>/dev/null || true)"
  if [ -n "$ids" ]; then
    # shellcheck disable=SC2086 # newline-separated ids on purpose
    docker rm -f $ids >/dev/null 2>&1 || true
  fi
  docker rm -f "$NAME" >/dev/null 2>&1 || true
}
cleanup() { reap; }
trap cleanup EXIT

# ---- prerequisites ---------------------------------------------------------
command -v docker >/dev/null 2>&1 || { printf 'FIXTURE: docker is not on PATH\n' >&2; exit 2; }
docker info >/dev/null 2>&1 || { printf 'FIXTURE: the docker daemon is not reachable\n' >&2; exit 2; }
docker image inspect "$TAG" >/dev/null 2>&1 || {
  printf 'FIXTURE: %s is not built; run build-image.sh first (this script never pulls)\n' "$TAG" >&2
  exit 2
}
for fixture in "${FIXTURES[@]}"; do
  [ -f "$fixture" ] || { printf 'FIXTURE: missing %s\n' "$fixture" >&2; exit 2; }
done
[ -f "$MATRIX" ] || { printf 'FIXTURE: missing %s\n' "$MATRIX" >&2; exit 2; }
for compose in "${COMPOSE_FILES[@]}"; do
  [ -f "$compose" ] || { printf 'FIXTURE: missing compose file %s\n' "$compose" >&2; exit 2; }
done

reap

# ---- the image facts -------------------------------------------------------
image_id="$(docker image inspect "$TAG" --format '{{.Id}}')"
image_bytes="$(docker image inspect "$TAG" --format '{{.Size}}')"
image_mb="$(awk -v b="$image_bytes" 'BEGIN{printf "%.1f", b/1000000}')"

printf '# MIT core PDF runtime — the run\n\n'
printf 'image:       %s\n' "$TAG"
printf 'image id:    %s\n' "$image_id"
printf 'image size:  %s bytes (%s MB)\n' "$image_bytes" "$image_mb"

jar_sha="$(docker run --rm --network none --entrypoint sha256sum "$TAG" /app/app.jar | awk '{print $1}')"
printf 'jar sha256:  %s\n' "$jar_sha"
[ "$jar_sha" = "$JAR_SHA256" ] && pass "the jar inside the image is the pinned artefact" \
  || fail "the jar inside the image is $jar_sha, not the pin"

# ---- start it: no network, non-root, read-only root, the deployment ceilings
# The tmpfs list and the limits are compose.example.yaml's, so this run is the
# deployment's own constraint set, not a looser one.
start_ns="$(date +%s%N)"
container_id="$(docker run -d --name "$NAME" --label "$LABEL" \
  --network none \
  --read-only \
  --user 1001:1001 \
  --cap-drop ALL \
  --security-opt no-new-privileges \
  --cpus 2 --memory 4g --memory-swap 4g --pids-limit 512 \
  --tmpfs /tmp:rw,exec,size=1536m,uid=1001,gid=1001,mode=1777 \
  --tmpfs /configs:rw,size=256m,uid=1001,gid=1001,mode=755 \
  --tmpfs /logs:rw,size=64m,uid=1001,gid=1001,mode=755 \
  --tmpfs /customFiles:rw,size=16m,uid=1001,gid=1001,mode=755 \
  --tmpfs /pipeline:rw,size=16m,uid=1001,gid=1001,mode=755 \
  --tmpfs /storage:rw,size=64m,uid=1001,gid=1001,mode=755 \
  --tmpfs /home/stirlingpdfuser:rw,exec,size=256m,uid=1001,gid=1001,mode=755 \
  "$TAG")"
printf '%s\n' "$container_id" > "$ID_FILE"

ready=""
for _ in $(seq 1 180); do
  if docker exec "$container_id" curl -fsS --max-time 2 \
       http://127.0.0.1:8080/api/v1/info/status >/dev/null 2>&1; then
    ready=yes; break
  fi
  sleep 1
done
end_ns="$(date +%s%N)"
if [ -z "$ready" ]; then
  fail "the image did not answer /api/v1/info/status within 180 s"
  docker logs --tail 40 "$container_id" >&2 || true
else
  cold_ms=$(( (end_ns - start_ns) / 1000000 ))
  printf 'cold start:  %s.%03d s (docker run -> first 200 on /api/v1/info/status)\n' \
    "$((cold_ms / 1000))" "$((cold_ms % 1000))"
  pass "the image starts offline and answers status 200"
fi

status_body="$(docker exec "$container_id" curl -fsS http://127.0.0.1:8080/api/v1/info/status)"
printf 'status:      %s\n' "$status_body"
case "$status_body" in
  *'"status":"UP"'*) pass 'status says UP' ;;
  *) fail 'status is not UP' ;;
esac

# `docker logs | grep -q` is a trap under `set -o pipefail`: grep exits after
# the first match, the writer gets SIGPIPE, and a successful check reads as 141.
# The captured string is compared instead.
logs="$(docker logs "$container_id" 2>&1 || true)"
case "$logs" in
  *"Without additional features in jar"*)
    pass 'the log says "Without additional features in jar" (the MIT core jar)' ;;
  *)
    fail 'the jar is not the MIT core build: the marker is absent from the log' ;;
esac

# ---- the licence floor at runtime -----------------------------------------
if docker exec "$container_id" sh -c 'command -v gs' >/dev/null 2>&1; then
  fail 'a gs binary is present; Ghostscript is excluded from this runtime (AGPL)'
else
  pass 'no gs binary in the image (Ghostscript excluded, AGPL)'
fi
tools_ok=yes
for tool in soffice qpdf pdftohtml; do
  docker exec "$container_id" sh -c "command -v $tool" >/dev/null 2>&1 || tools_ok=no
done
[ "$tools_ok" = yes ] && pass 'soffice, qpdf and pdftohtml are present' \
  || fail 'one of soffice, qpdf, pdftohtml is missing'

# The artefact carries the no-telemetry switches itself, so a deployment that
# forgot them is still silent; the compose file sets the same four.
telemetry_ok=yes
for key in SYSTEM_ENABLEANALYTICS SYSTEM_ENABLEPOSTHOG SYSTEM_SHOWUPDATE SYSTEM_ENABLEURLTOPDF; do
  docker exec "$container_id" sh -c "[ \"\$$key\" = false ]" || telemetry_ok=no
done
[ "$telemetry_ok" = yes ] && pass 'the image sets analytics, PostHog, update check and URL-to-PDF to false' \
  || fail 'a no-telemetry switch is missing from the image environment'

# ---- no egress -------------------------------------------------------------
interfaces="$(docker exec "$container_id" sh -c 'cat /proc/net/dev' | awk -F: 'NR>2 {gsub(/ /,"",$1); print $1}' | tr '\n' ' ')"
routes="$(docker exec "$container_id" sh -c 'cat /proc/net/route' | tail -n +2 | wc -l)"
printf 'egress:      interfaces=%s routes=%s\n' "${interfaces:-none}" "$routes"
if [ "$interfaces" = "lo " ] && [ "$routes" = 0 ]; then
  pass 'the container has only loopback and no route (--network none)'
else
  fail "unexpected network surface: interfaces=${interfaces} routes=${routes}"
fi
if docker exec "$container_id" sh -c 'curl -sS --max-time 5 https://example.com -o /dev/null' >/dev/null 2>&1; then
  fail 'an outbound HTTPS request succeeded'
else
  pass 'an outbound HTTPS request fails (DNS cannot resolve; no egress)'
fi

# ---- the compose wiring ----------------------------------------------------
for compose in "${COMPOSE_FILES[@]}"; do
  compose_name="$(basename "$compose")"
  if grep -qE '^[[:space:]]+internal:[[:space:]]*true[[:space:]]*$' "$compose"; then
    pass "$compose_name keeps its network internal: true"
  else
    fail "$compose_name no longer declares internal: true"
  fi
  if grep -qE '^[[:space:]]+ports:' "$compose"; then
    fail "$compose_name publishes a port"
  else
    pass "$compose_name publishes no port"
  fi
done

# ---- the matrix ------------------------------------------------------------
docker exec "$container_id" mkdir -p /tmp/proof
for fixture in "${FIXTURES[@]}"; do
  base="$(basename "$fixture")"
  docker exec -i "$container_id" sh -c "cat > /tmp/proof/$base" < "$fixture"
done
docker exec -i "$container_id" sh -c 'cat > /tmp/proof/endpoint-matrix.sh' < "$MATRIX"

set +e
docker exec "$container_id" sh /tmp/proof/endpoint-matrix.sh
matrix_exit=$?
set -e
if [ "$matrix_exit" -eq 0 ]; then
  pass 'the endpoint matrix passed (outputs checked, disabled endpoints answered 403)'
else
  fail "the endpoint matrix exited $matrix_exit"
fi

# ---- tear down, and prove it is gone --------------------------------------
docker rm -f "$container_id" >/dev/null 2>&1 || true
rm -f "$ID_FILE"
left_ids="$(docker ps -aq --filter "label=$LABEL" || true)"
left_name="$(docker ps -aq --filter "name=^/${NAME}$" || true)"
if [ -z "$left_ids" ] && [ -z "$left_name" ]; then
  pass 'the proof container is gone (no container with the label or the name)'
else
  fail "a proof container survived: label=${left_ids:-none} name=${left_name:-none}"
fi

printf '\nRESULT failures=%s\n' "$failures"
[ "$failures" -eq 0 ] && printf 'PASS  the MIT core runtime starts offline and serves the v1 verbs\n'
[ "$failures" -eq 0 ] || printf 'FAIL  %s assertion(s) failed\n' "$failures"
exit "$([ "$failures" -eq 0 ] && echo 0 || echo 1)"

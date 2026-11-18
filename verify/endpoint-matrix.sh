#!/bin/sh
# The endpoint matrix of the MIT core PDF runtime, run INSIDE the container by
# verify-runtime.sh.
#
# This half owns no lifecycle: the host script starts the container with
# `--network none`, copies this file and the fixtures into /tmp/proof, and
# removes the container afterwards. Every request is made to 127.0.0.1, so the
# matrix cannot pass by reaching something outside the container.
#
# Every enabled row checks the OUTPUT, not only the status: a PDF's page count
# and its text, a PDF/A's part marker, the markdown's extracted text, and the
# output size. A row that returns 200 with a wrong page count is a FAIL here.
#
# The disabled rows assert the product's own answer to a disabled endpoint —
# 403 with a JSON body — because "not 500, not an empty file" is the contract.
#
# Output is the table pasted into the proof document. Exit: 0 all rows passed,
# 1 a row failed.
set -u

BASE="http://127.0.0.1:8080"
DIR=/tmp/proof
FIXTURES="$DIR"
failures=0

pass() { printf 'PASS  %s\n' "$*"; }
fail() { printf 'FAIL  %s\n' "$*"; failures=$((failures + 1)); }

# probe OUT CURL_ARGS... — one request, prints `http=%s type=%s size=%s time=%s`.
# The caller reads the key=value line and the output file.
probe() {
  out="$1"; shift
  # shellcheck disable=SC2086 # the caller passes a word list on purpose
  curl -s -o "$out" -w 'http=%{http_code} type=%{content_type} size=%{size_download} time=%{time_total}' "$@"
}

field() { printf '%s\n' "$1" | tr ' ' '\n' | sed -n "s/^$2=//p"; }

pages() { pdfinfo "$1" 2>/dev/null | awk '/^Pages:/{print $2}'; }

row() { # endpoint fixture expected-pages check-verdict detail seconds bytes
  printf '| %s | %s | %s | %s | %s | %s | %s |\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7"
}

printf '# MIT core PDF runtime — endpoint matrix (inside the container, --network none)\n\n'
printf 'base: %s\n' "$BASE"
printf 'engine: %s\n\n' "$(curl -s "$BASE/api/v1/info/status")"

printf '## Enabled endpoints\n\n'
printf '| endpoint | fixture | http | pages | output check | seconds | bytes |\n'
printf '|---|---|---|---|---|---|---|\n'

# ---- pdf-to-pdfa -----------------------------------------------------------
# The endpoint has two MIT paths: with `useStirlingOfficeConvert=true` it uses
# the jar's own stirling-office-convert-pdfa library (LibreOffice under the
# hood); with the field absent or false it uses the PDFBox path. Neither needs
# Ghostscript, so both are exercised: a caller that omits the field gets the
# same MIT result, not a silent 500 on a gs-free host.
for variant in default office; do
  for spec in "base-1p.pdf 1" "base-50p.pdf 50"; do
    set -- $spec; fixture=$1; expected=$2
    name="pdfa-$variant-$2p.pdf"
    extra=""
    [ "$variant" = office ] && extra="-F useStirlingOfficeConvert=true"
    # shellcheck disable=SC2086 # extra is a flag word list or empty
    line=$(probe "$DIR/$name" -F "fileInput=@$FIXTURES/$fixture" \
      -F outputFormat=pdfa $extra \
      "$BASE/api/v1/convert/pdf/pdfa")
    http=$(field "$line" http); size=$(field "$line" size); secs=$(field "$line" time)
    got=$(pages "$DIR/$name")
    verdict=FAIL
    if [ "$http" = 200 ] && [ "$got" = "$expected" ] && [ "${size:-0}" -gt 1000 ] \
       && pdftotext "$DIR/$name" - 2>/dev/null | grep -q 'RE-2026-0042' \
       && grep -qa 'pdfaid:part' "$DIR/$name"; then
      verdict=PASS
    fi
    row "pdf-to-pdfa ($variant)" "$fixture" "$http" "$got/$expected" "text+pdfa-marker:$verdict" "$secs" "$size"
    [ "$verdict" = PASS ] || fail "pdf-to-pdfa ($variant) on $fixture"
  done
done

# ---- compress --------------------------------------------------------------
# qpdf-based compression. The one-page fixture is a text-only reportlab file
# with nothing to remove, and the engine returns it byte-identical; the
# fifty-page fixture must get smaller. Both must stay valid PDFs with every
# page and the marker text intact.
for spec in "base-1p.pdf 1 p0001" "base-50p.pdf 50 p0050"; do
  set -- $spec; fixture=$1; expected=$2; marker=$3; name="compress-$2p.pdf"
  line=$(probe "$DIR/$name" -F "fileInput=@$FIXTURES/$fixture" \
    -F optimizeLevel=3 -F expectedOutputSize=25KB \
    -F linearize=false -F normalize=false -F grayscale=false \
    "$BASE/api/v1/misc/compress-pdf")
  http=$(field "$line" http); size=$(field "$line" size); secs=$(field "$line" time)
  got=$(pages "$DIR/$name")
  input_size=$(wc -c < "$FIXTURES/$fixture")
  verdict=FAIL
  if [ "$http" = 200 ] && [ "$got" = "$expected" ] && [ "${size:-0}" -gt 1000 ] \
     && pdftotext "$DIR/$name" - 2>/dev/null | grep -q "$marker"; then
    if [ "$expected" = 50 ] && [ "$size" -lt "$input_size" ]; then verdict=PASS; fi
    if [ "$expected" = 1 ]; then verdict=PASS; fi
  fi
  row compress "$fixture" "$http" "$got/$expected" "text+size:$verdict" "$secs" "$size ($input_size in)"
  [ "$verdict" = PASS ] || fail "compress on $fixture"
done

# ---- docx -> pdf (LibreOffice) ---------------------------------------------
# A Word file goes in; a PDF comes out. The fifty-page fixture names its page
# in the canary line, so the check proves pagination by counting 50 canaries,
# not by trusting the page count alone.
for spec in "office-1p.docx 1" "office-50p.docx 50"; do
  set -- $spec; fixture=$1; expected=$2; name="office-$2p.pdf"
  line=$(probe "$DIR/$name" -F "fileInput=@$FIXTURES/$fixture" \
    "$BASE/api/v1/convert/file/pdf")
  http=$(field "$line" http); size=$(field "$line" size); secs=$(field "$line" time)
  got=$(pages "$DIR/$name")
  canaries=$(pdftotext "$DIR/$name" - 2>/dev/null | grep -c 'STIRLING-CORE-CANARY')
  verdict=FAIL
  if [ "$http" = 200 ] && [ "$got" = "$expected" ] && [ "${size:-0}" -gt 1000 ] \
     && [ "$canaries" = "$expected" ]; then
    verdict=PASS
  fi
  row docx-to-pdf "$fixture" "$http" "$got/$expected" "canaries:$canaries/$expected:$verdict" "$secs" "$size"
  [ "$verdict" = PASS ] || fail "docx-to-pdf on $fixture"
done

# ---- poppler text extraction ----------------------------------------------
# pdftohtml (poppler) extracts the text, and the markdown endpoint renders that
# extraction. The check looks for the invoice's text and the page marker, so a
# truncated extraction fails on either fixture.
for spec in "base-1p.pdf 1 p0001" "base-50p.pdf 50 p0050"; do
  set -- $spec; fixture=$1; expected=$2; marker=$3; name="markdown-$2p.md"
  line=$(probe "$DIR/$name" -F "fileInput=@$FIXTURES/$fixture" \
    "$BASE/api/v1/convert/pdf/markdown")
  http=$(field "$line" http); size=$(field "$line" size); secs=$(field "$line" time)
  verdict=FAIL
  if [ "$http" = 200 ] && [ "${size:-0}" -gt 100 ] \
     && grep -q 'RE-2026-0042' "$DIR/$name" \
     && grep -q "$marker" "$DIR/$name"; then
    verdict=PASS
  fi
  row poppler-text "$fixture" "$http" "-" "markdown-text:$verdict" "$secs" "$size"
  [ "$verdict" = PASS ] || fail "poppler text extraction on $fixture"
done

printf '\n## Disabled endpoints (Ghostscript excluded by the licence floor)\n\n'
printf '| endpoint | http | type | bytes | answer |\n'
printf '|---|---|---|---|---|\n'

# Every row here is disabled by the engine's own external-dependency probe,
# because `gs` is absent by design. The contract is the product's answer: 403
# with a JSON body, never a 500 and never an empty file.
negative() { # endpoint path fixture
  out="$DIR/neg-$1.json"
  line=$(probe "$out" -F "fileInput=@$FIXTURES/$3" "$BASE/api/v1$2")
  http=$(field "$line" http); type=$(field "$line" type); size=$(field "$line" size)
  answer=none
  [ -s "$out" ] && answer=$(head -c 200 "$out")
  verdict=FAIL
  if [ "$http" = 403 ] && [ "$type" = application/json ] && [ "${size:-0}" -gt 0 ] \
     && grep -q '"status":403' "$out"; then
    verdict=PASS
  fi
  printf '| %s | %s | %s | %s | %s (%s) |\n' "$1" "$http" "$type" "$size" "$verdict" "$answer"
  [ "$verdict" = PASS ] || fail "negative $1"
}

negative repair             /misc/repair              base-1p.pdf
negative scanner-effect     /misc/scanner-effect      base-1p.pdf
negative replace-invert-pdf /misc/replace-invert-pdf base-1p.pdf
negative pdf-to-vector      /convert/pdf/vector      base-1p.pdf
negative vector-to-pdf      /convert/vector/pdf      base-1p.pdf
negative pdf-to-ua          /misc/pdf-to-ua          base-1p.pdf

printf '\nRESULT failures=%s\n' "$failures"
[ "$failures" -eq 0 ] && printf 'PASS  every enabled endpoint produced its checked output; every disabled endpoint answered 403\n'
[ "$failures" -eq 0 ] || printf 'FAIL  %s row(s) failed\n' "$failures"
exit "$([ "$failures" -eq 0 ] && echo 0 || echo 1)"

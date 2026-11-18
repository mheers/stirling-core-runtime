# stirling-core-runtime

An **unofficial**, self-hosted build of the Stirling PDF **MIT core** server jar
with the free tooling it needs, packaged as a container image that runs with no
network, no login and no storage.

It is not affiliated with, endorsed by or supported by Stirling PDF. It is not
a reimplementation: it runs the upstream `Stirling-PDF-server.jar` v3.3.0
release, unmodified, with a pinned sha256.

```
mheers/stirling-core-runtime:3.3.0-core.1
```

## What it is

Upstream publishes the server as a single fat jar and ships a much larger
application around it. This image is the jar plus the tools the document verbs
actually call:

| Piece | What it is |
|---|---|
| `Stirling-PDF-server.jar` | v3.3.0, MIT core, the release asset, sha256 `5cb59682…2557c` |
| LibreOffice Writer/Draw (no GUI) | `docx`/`pptx`/`xlsx` → PDF, and the PDF/A office path |
| qpdf | compression, linearisation, the repair fallback |
| poppler-utils | text and image extraction (`pdftohtml`, `pdfimages`) |
| DejaVu and Liberation fonts | metric-compatible substitutes for Arial/Calibri/Times |
| Temurin 25 JRE | the runtime, on Ubuntu 24.04 (noble) |

The engine is the MIT core build: no proprietary classes, no SaaS classes, no
licence check, and no outbound call. The build does not compile the jar and
does not touch upstream's source — it downloads the release asset and verifies
its sha256 twice (once in `build-image.sh`, once inside the Docker build).

## What is deliberately absent

| Absent | Why |
|---|---|
| Login, session store, admin UI | The engine is reached only by another container on a network with no gateway. There is nothing to log into. |
| Storage, volumes, document history | Every writable path is a tmpfs. A restart has no history. |
| Audit trail | The caller keeps the audit trail; the engine is a pure function of its input. |
| The AI engine, the Processor/portal frontend | Proprietary or out of scope for this runtime. |
| Ghostscript | AGPL; excluded by the licence floor. Verbs that require it answer `403` with a JSON body. |
| OCR (tesseract/ocrmypdf), Calibre, WeasyPrint, ImageMagick, URL-to-PDF | Not installed. These are free licences, not licence problems; a later build can add them. |
| PDF/UA | The MIT core build has no PDF/UA controller; the path answers `403`. |

PDF/A works without Ghostscript on both of the engine's own paths: the PDFBox
path and the office-convert path (`useStirlingOfficeConvert=true`).

## Build

The build context is this directory. It downloads the pinned jar into it:

```sh
./build-image.sh                 # builds stirling-core-runtime:dev
./build-image.sh my/tag:1.2.3    # or any tag you like
```

Requirements: Docker with BuildKit, `curl`, and egress for the release asset and
the Ubuntu package mirror. The base image is pinned by manifest digest, so a
rebuild resolves the same JVM.

## Run

`compose.example.yaml` is the boundary this image is designed for: an internal
network, no published port, a read-only root, a non-root user, and memory/pid
ceilings.

```sh
docker compose -p pdf-tools -f compose.example.yaml up -d --wait
```

From another container on the `pdf-tools` network:

```sh
curl -fsS http://pdf-tools:8080/api/v1/info/status
# {"version":"3.3.0","status":"UP"}
```

There is no host port on purpose. If you need to call the engine from the host,
put your client in a container on the same network — a published port on a
service that parses untrusted documents is the thing this posture removes.

The image is a service, not a CLI: every operation is an HTTP call to
`/api/v1/...`. The request and response shape is upstream's; see
[Stirling PDF's API documentation](https://docs.stirlingpdf.com/).

## Verify

Everything here is checked by a program, not a paragraph:

```sh
# 1. The engine: image facts, cold start, the endpoint matrix, and the
#    negative table (no gs, no egress, no published port).
./verify-runtime.sh

# 2. The licence floor, against the jar inside the image.
docker run --rm --network none --entrypoint cat stirling-core-runtime:dev /app/app.jar > /tmp/app.jar
python3 licence_scan.py --jar /tmp/app.jar

# 3. The scan's own failure paths, so a green scan is not a scan that never looked.
python3 test_licence_scan.py

# 4. The SBOM generator (CycloneDX 1.5) and its determinism.
python3 test_sbom.py
```

`verify-runtime.sh` starts one container with `--network none`, the same
read-only root and ceilings the example deployment uses, waits for
`/api/v1/info/status`, runs the endpoint matrix **inside** the container, and
removes the container afterwards. Every enabled row checks the output — page
count, extracted text, PDF/A marker, canary count, size — not only the status
code. Every disabled row asserts the engine's own `403` JSON answer, not a 500
and not an empty file.

The scripts are leak-proof by construction: the container's id is recorded
under `${TMPDIR:-/tmp}/stirling-core-runtime/verify/` as it starts, a previous
invocation's container is removed at the start of the next run, and the end
asserts that nothing carrying the proof label remains. No `trap` is relied on.

## No egress

The image makes no outbound call of its own: analytics, PostHog, the Scarf
pixel, the update check and URL-to-PDF are switched off in the image
environment, and the example deployment puts the container on an `internal:
true` network with no gateway. The proof runs the container with
`--network none` and shows only loopback, an empty route table, and a failing
outbound request.

## Licence

* The files in this repository — the Dockerfile, the scripts, the fixtures and
  the documentation — are MIT. See `LICENSE`.
* The upstream jar is MIT, published by the Stirling PDF project. It embeds 450
  third-party libraries under their own licences; the list is
  `licences/3rdPartyLicenses.json`, extracted verbatim from the jar.
* The runtime packages (LibreOffice, poppler, Temurin and the Ubuntu base) carry
  their own licences, including GPL-2.0, LGPL and MPL-2.0. `NOTICE` names them,
  and `SOURCE_OFFER.md` carries the written offer for their source.

`sbom.cdx.json` is a CycloneDX 1.5 SBOM of the image: the jar, every library in
its BOM, and every Debian package in the image's OS layer.

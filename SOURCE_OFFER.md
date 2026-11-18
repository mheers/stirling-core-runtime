# Source offer

The `mheers/stirling-core-runtime` image contains free-software components that
are distributed under licences requiring their corresponding source to be
available: the GPL-2.0 (poppler, the Temurin JDK), the LGPL-3.0 and MPL-2.0
(LibreOffice) and the MPL-2.0 (`ca-certificates`).

This is the **written offer** for that source. The exact versions below were
observed inside the published image with
`docker run --rm --entrypoint dpkg-query <image> -W -f '${Package}\t${Version}\n'`.

## How to get the source

For each component, the complete corresponding source is available at the
location named below, free of charge, for as long as this release is published
and for at least three years after it. If a location is unreachable or a
version is no longer mirrored, open an issue at
<https://github.com/mheers/stirling-core-runtime/issues> and a copy will be
provided.

The general recipe on any Ubuntu 24.04 host with `deb-src` enabled is:

```sh
apt-get source <source-package>=<version>
```

The archive pools below hold both the original tarball and the Debian patch
set for the Ubuntu build.

## Ubuntu 24.04 (noble) packages

| Binary package (version in the image) | Source package | Licence | Source location |
|---|---|---|---|
| `poppler-utils` 24.02.0-1ubuntu9.11 | `poppler` | GPL-2.0-or-later | <https://archive.ubuntu.com/ubuntu/pool/main/p/poppler/> |
| `libreoffice-core`, `libreoffice-common`, `libreoffice-writer-nogui`, `libreoffice-draw-nogui` 4:24.2.7-0ubuntu0.24.04.7 | `libreoffice` | MPL-2.0 and LGPL-3.0 | <https://archive.ubuntu.com/ubuntu/pool/main/libr/libreoffice/> |
| `qpdf` 11.9.0-1.1ubuntu0.1 | `qpdf` | Apache-2.0 | <https://archive.ubuntu.com/ubuntu/pool/main/q/qpdf/> |
| `ca-certificates` 20260816ubuntu0.24.04.2 | `ca-certificates` | MPL-2.0 | <https://archive.ubuntu.com/ubuntu/pool/main/c/ca-certificates/> |
| `tini` 0.19.0-1 | `tini` | MIT | <https://archive.ubuntu.com/ubuntu/pool/universe/t/tini/> |
| `curl` 8.5.0-2ubuntu10.16 | `curl` | curl licence | <https://archive.ubuntu.com/ubuntu/pool/main/c/curl/> |
| `fonts-dejavu-core` 2.37-8 | `fonts-dejavu` | DejaVu licence | <https://archive.ubuntu.com/ubuntu/pool/main/f/fonts-dejavu/> |
| `fonts-liberation2` 1:2.1.5-3 | `fonts-liberation2` | SIL OFL-1.1 | <https://archive.ubuntu.com/ubuntu/pool/main/f/fonts-liberation2/> |

Security updates for these packages are published in the same layout at
<https://security.ubuntu.com/ubuntu/pool/>.

## Temurin 25 (OpenJDK 25.0.5+8)

The base image is `eclipse-temurin:25-jre-noble`, built by the Eclipse Adoptium
project from OpenJDK, under GPL-2.0 with the Classpath Exception.

| Component | Version | Source |
|---|---|---|
| Temurin 25 JRE | 25.0.5+8 | <https://github.com/adoptium/temurin25-binaries/releases/tag/jdk-25.0.5%2B8> |
| OpenJDK 25 update source | jdk-25.0.5+8 | <https://github.com/openjdk/jdk25u> |
| Adoptium build scripts | matching tag | <https://github.com/adoptium/temurin-build> |

The base image is pinned in the Dockerfile by manifest digest
`sha256:e3b6f7887a50f20d8f07abf279d8a81a5953fb398a9555bd9edd56b9bd15968c`.

## Upstream jar and its libraries

The server jar is the upstream MIT release asset, unmodified. Its 450 embedded
libraries and their licences are listed verbatim in
`licences/3rdPartyLicenses.json`; where a library's licence requires source,
its own project publishes it, and the SBOM (`sbom.cdx.json`) names the exact
version to fetch. The jar itself is reproducible from
<https://github.com/Stirling-Tools/Stirling-PDF/releases/tag/v3.3.0> and is
verified by sha256
`5cb59682f93bd7d48312d36a87585ef2e8ca9ddfa64bc210dea6bd882925557c`.

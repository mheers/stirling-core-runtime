#!/usr/bin/env python3
"""Generate a CycloneDX SBOM for the MIT core PDF runtime image.

Two inputs, both facts about the built artefact rather than a hand-kept list:

  * the jar's own BOM, `BOOT-INF/classes/static/3rdPartyLicenses.json`, which
    upstream ships inside `Stirling-PDF-server.jar` — 450 libraries with their
    declared versions and licences;
  * the runtime package list, `dpkg-query -W` run inside the image — the
    Debian packages the OS layer actually contains.

The output is deterministic: no timestamp and a serial number derived from the
jar's sha256, so two runs on the same artefacts produce the same bytes.

Usage:
  sbom.py --jar app.jar --packages packages.tsv --output sbom.cdx.json \
          [--licences-out licences/3rdPartyLicenses.json] \
          [--image IMAGE] [--image-version VERSION]

Exit: 0 written, 2 an input is missing or unreadable.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
import uuid
import zipfile
from pathlib import Path

# The BOM's `moduleLicense` values are free text. Map the unambiguous ones to
# SPDX identifiers and keep the rest verbatim as a licence name: a wrong SPDX id
# is worse than an honest name.
SPDX_IDS = {
    "Apache License, Version 2.0": "Apache-2.0",
    "The Apache Software License, Version 2.0": "Apache-2.0",
    "The Apache License, Version 2.0": "Apache-2.0",
    "Apache License 2.0": "Apache-2.0",
    "Apache License, version 2.0": "Apache-2.0",
    "Apache-2.0": "Apache-2.0",
    "Apache 2.0": "Apache-2.0",
    "Apache 2": "Apache-2.0",
    "MIT License": "MIT",
    "The MIT License": "MIT",
    "MIT": "MIT",
    "EPL-2.0": "EPL-2.0",
    "BSD 2-Clause License": "BSD-2-Clause",
    "BSD-2-Clause": "BSD-2-Clause",
    "BSD-3-Clause": "BSD-3-Clause",
    "The BSD 3-Clause License (BSD3)": "BSD-3-Clause",
    "Mozilla Public License 2.0 (MPL-2.0)": "MPL-2.0",
    "MPL 2.0": "MPL-2.0",
    "LGPL-2.1-only": "LGPL-2.1-only",
    "COMMON DEVELOPMENT AND DISTRIBUTION LICENSE (CDDL) Version 1.0": "CDDL-1.0",
}

BOM_PATH = "BOOT-INF/classes/static/3rdPartyLicenses.json"
JAR_NAME = "app.jar"
JAR_VERSION = "3.3.0"
JAR_URL = ("https://github.com/Stirling-Tools/Stirling-PDF/releases/download/"
           "v3.3.0/Stirling-PDF-server.jar")


def licence_of(text: str | None) -> dict:
    if not text:
        return {"license": {"name": "unknown"}}
    spdx = SPDX_IDS.get(text.strip())
    return {"license": {"id": spdx} if spdx else {"name": text.strip()}}


def jar_component(sha256: str) -> dict:
    return {
        "type": "application",
        "bom-ref": f"pkg:generic/stirling-pdf-server@{JAR_VERSION}",
        "name": "Stirling-PDF-server.jar",
        "version": JAR_VERSION,
        "purl": f"pkg:generic/stirling-pdf-server@{JAR_VERSION}",
        "externalReferences": [{"type": "distribution", "url": JAR_URL}],
        "hashes": [{"alg": "SHA-256", "content": sha256}],
        "licenses": [{"license": {"id": "MIT"}}],
        "description": "Upstream MIT core release asset, reused unmodified.",
    }


def jar_components(jar_path: Path) -> list[dict]:
    with zipfile.ZipFile(jar_path) as jar:
        document = json.loads(jar.read(BOM_PATH).decode("utf-8"))
    components = []
    for module in document.get("dependencies") or []:
        name = str(module.get("moduleName") or "").strip()
        if ":" not in name:
            continue
        group, artifact = name.split(":", 1)
        version = str(module.get("moduleVersion") or "").strip() or "0"
        component = {
            "type": "library",
            "bom-ref": f"pkg:maven/{group}/{artifact}@{version}",
            "group": group,
            "name": artifact,
            "version": version,
            "purl": f"pkg:maven/{group}/{artifact}@{version}",
            "licenses": [licence_of(module.get("moduleLicense"))],
        }
        if module.get("moduleUrl"):
            component["externalReferences"] = [{"type": "website", "url": module["moduleUrl"]}]
        components.append(component)
    return components


def package_components(packages_path: Path) -> list[dict]:
    """`dpkg-query -W -f '${Package}\\t${Version}\\t${Architecture}\\n'` output."""
    components = []
    for line in packages_path.read_text().splitlines():
        parts = line.split("\t")
        if len(parts) < 2 or not parts[0]:
            continue
        package, version = parts[0], parts[1]
        arch = parts[2] if len(parts) > 2 and parts[2] else "amd64"
        purl = f"pkg:deb/ubuntu/{package}@{version}?arch={arch}"
        components.append({
            "type": "library",
            "bom-ref": purl,
            "name": package,
            "version": version,
            "purl": purl,
            "properties": [{"name": "dpkg:architecture", "value": arch}],
        })
    return components


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jar", default=JAR_NAME)
    parser.add_argument("--packages", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--licences-out", default=None,
                        help="write the jar's raw 3rdPartyLicenses.json here")
    parser.add_argument("--image", default="stirling-core-runtime")
    parser.add_argument("--image-version", default="dev")
    args = parser.parse_args()

    jar_path = Path(args.jar)
    packages_path = Path(args.packages)
    if not jar_path.is_file():
        print(f"FAIL  {jar_path} is missing", file=sys.stderr)
        return 2
    if not packages_path.is_file():
        print(f"FAIL  {packages_path} is missing", file=sys.stderr)
        return 2

    sha256 = hashlib.sha256(jar_path.read_bytes()).hexdigest()
    with zipfile.ZipFile(jar_path) as jar:
        raw_licences = jar.read(BOM_PATH)
    if args.licences_out:
        out = Path(args.licences_out)
        out.parent.mkdir(parents=True, exist_ok=True)
        out.write_bytes(raw_licences)
        print(f"wrote {out} ({len(raw_licences)} bytes)")

    components = [jar_component(sha256)]
    components += jar_components(jar_path)
    components += package_components(packages_path)
    components.sort(key=lambda component: component["bom-ref"])

    document = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "serialNumber": "urn:uuid:" + str(uuid.uuid5(
            uuid.NAMESPACE_URL,
            f"https://github.com/mheers/stirling-core-runtime#{sha256}",
        )),
        "version": 1,
        "metadata": {
            "tools": [{"name": "stirling-core-runtime sbom.py", "version": "1.5"}],
            "component": {
                "type": "container",
                "bom-ref": f"pkg:oci/{args.image}@{args.image_version}",
                "name": args.image,
                "version": args.image_version,
                "purl": f"pkg:oci/{args.image}@{args.image_version}",
            },
        },
        "components": components,
    }

    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(document, indent=2, sort_keys=False) + "\n")
    print(f"wrote {output} ({len(components)} components, jar sha256 {sha256})")
    return 0


if __name__ == "__main__":
    sys.exit(main())

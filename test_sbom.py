#!/usr/bin/env python3
"""The SBOM generator's own test.

`sbom.py` is part of the release, so its two properties have to be proven, not
assumed: it reads the jar's BOM and the image's package list, and it is
deterministic — two runs on the same artefacts must produce the same bytes, or
a reviewer cannot compare two releases.

Run: python3 test_sbom.py
Exit: 0 every case passed, 1 a case failed, 2 the generator is missing.
"""

from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SBOM = HERE / "sbom.py"

BOM = json.dumps({
    "dependencies": [
        {"moduleName": "ch.qos.logback:logback-classic",
         "moduleVersion": "1.5.38", "moduleLicense": "LGPL-2.1-only"},
        {"moduleName": "org.apache.commons:commons-lang3",
         "moduleVersion": "3.19.0", "moduleLicense": "Apache License, Version 2.0"},
        {"moduleName": "com.stirling:jpdfium",
         "moduleVersion": "1.1.6", "moduleLicense": "MIT License"},
        {"moduleName": "not-a-module",
         "moduleVersion": "1.0", "moduleLicense": "MIT License"},
    ],
    "importedModules": {},
}).encode()

PACKAGES = (
    "libreoffice-writer-nogui\t25.2.7-0ubuntu0.24.04.1\tamd64\n"
    "qpdf\t11.9.1-1build1\tamd64\n"
)

failures: list[str] = []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        print(f"PASS  {name}")
    else:
        failures.append(name)
        print(f"FAIL  {name}{': ' + detail if detail else ''}")


def run(root: Path, jar: Path, packages: Path, output: Path, licences: Path) -> tuple[int, str]:
    result = subprocess.run(
        [sys.executable, str(SBOM), "--jar", str(jar), "--packages", str(packages),
         "--output", str(output), "--licences-out", str(licences),
         "--image", "example/runtime", "--image-version", "3.3.0-core.1"],
        capture_output=True, text=True,
    )
    return result.returncode, result.stdout + result.stderr


def main() -> int:
    if not SBOM.is_file():
        print(f"FAIL  {SBOM} is missing", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="sbom-test-") as directory:
        root = Path(directory)
        jar = root / "app.jar"
        with zipfile.ZipFile(jar, "w") as archive:
            archive.writestr("BOOT-INF/classes/static/3rdPartyLicenses.json", BOM)
        packages = root / "packages.tsv"
        packages.write_text(PACKAGES)

        first = root / "first.json"
        licences = root / "licences" / "3rdPartyLicenses.json"
        code, output = run(root, jar, packages, first, licences)
        check("the generator exits 0 on a synthetic input", code == 0, output)
        if code != 0:
            print(json.dumps(failures))
            return 1

        document = json.loads(first.read_text())
        check("the output is CycloneDX 1.5",
              document.get("bomFormat") == "CycloneDX" and document.get("specVersion") == "1.5")
        refs = [component["bom-ref"] for component in document["components"]]
        check("the jar is a component",
              any(ref.startswith("pkg:generic/stirling-pdf-server@3.3.0") for ref in refs), str(refs))
        check("the jar's libraries are components",
              "pkg:maven/com.stirling/jpdfium@1.1.6" in refs, str(refs))
        check("a module without a group is skipped", "not-a-module" not in " ".join(refs))
        check("the runtime packages are components",
              any(ref.startswith("pkg:deb/ubuntu/qpdf@11.9.1") for ref in refs), str(refs))
        check("the container carries the release version",
              document["metadata"]["component"]["version"] == "3.3.0-core.1")
        check("the raw licence list is written byte for byte", licences.read_bytes() == BOM)

        licences_by_ref = {
            component["bom-ref"]: (component.get("licenses") or [{}])[0].get("license", {})
            for component in document["components"]
        }
        check("an SPDX-mapped licence keeps its identifier",
              licences_by_ref["pkg:maven/org.apache.commons/commons-lang3@3.19.0"].get("id")
              == "Apache-2.0", str(licences_by_ref.get(
                  "pkg:maven/org.apache.commons/commons-lang3@3.19.0")))
        check("an unmapped licence is kept verbatim",
              licences_by_ref["pkg:maven/com.stirling/jpdfium@1.1.6"].get("id") == "MIT")

        second = root / "second.json"
        run(root, jar, packages, second, root / "licences-2.json")
        check("two runs produce the same bytes", first.read_bytes() == second.read_bytes())

        missing = root / "missing.tsv"
        code, _ = run(root, jar, missing, root / "third.json", root / "licences-3.json")
        check("a missing package list is refused with 2", code == 2)

    print()
    if failures:
        print(f"FAIL  {len(failures)} case(s) failed")
        return 1
    print("PASS  the SBOM reads both inputs and is deterministic")
    return 0


if __name__ == "__main__":
    sys.exit(main())

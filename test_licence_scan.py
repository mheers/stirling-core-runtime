#!/usr/bin/env python3
"""The licence scan's own test.

`licence_scan.py` is the licence floor, so its failure paths must be proven,
not assumed: a scan that only ever sees a clean jar cannot be trusted to
reject a dirty one. This test builds small synthetic jars in a temporary
directory — no network, no real jar — and checks each rule in both directions.

Run: python3 test_licence_scan.py
Exit: 0 every case passed, 1 a case failed, 2 the scan script is missing.
"""

from __future__ import annotations

import hashlib
import io
import json
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCAN = HERE / "licence_scan.py"

MANIFEST = (
    "Manifest-Version: 1.0\r\n"
    "Implementation-Title: Stirling-PDF\r\n"
    "Implementation-Version: 3.3.0\r\n"
    "\r\n"
)

CLEAN_BOM = json.dumps({
    "dependencies": [
        {"moduleName": "com.stirling:stirling-office-convert",
         "moduleVersion": "0.3.3", "moduleLicense": "MIT License"},
        {"moduleName": "com.stirling:jpdfium",
         "moduleVersion": "1.1.6", "moduleLicense": "MIT License"},
        {"moduleName": "ch.qos.logback:logback-classic",
         "moduleVersion": "1.5.38", "moduleLicense": "LGPL-2.1-only"},
    ],
    "importedModules": {},
}).encode()

failures: list[str] = []


def make_jar(path: Path, entries: dict[str, bytes]) -> str:
    with zipfile.ZipFile(path, "w") as archive:
        archive.writestr("META-INF/MANIFEST.MF", MANIFEST)
        for name, payload in entries.items():
            archive.writestr(name, payload)
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(jar: Path, sha: str) -> tuple[int, str]:
    result = subprocess.run(
        [sys.executable, str(SCAN), "--jar", str(jar), "--sha256", sha],
        capture_output=True, text=True,
    )
    return result.returncode, result.stdout + result.stderr


def case(name: str, want: int, jar: Path, sha: str, needle: str) -> None:
    code, output = run(jar, sha)
    if code != want:
        failures.append(f"{name}: exit {code}, want {want}\n{output}")
        print(f"FAIL  {name}: exit {code}, want {want}")
        return
    if needle not in output:
        failures.append(f"{name}: output does not name {needle!r}")
        print(f"FAIL  {name}: output does not name {needle!r}")
        return
    print(f"PASS  {name}")


def main() -> int:
    if not SCAN.is_file():
        print(f"FAIL  {SCAN} is missing", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="licence-scan-test-") as directory:
        root = Path(directory)

        clean = root / "clean.jar"
        clean_sha = make_jar(clean, {
            "BOOT-INF/classes/stirling/software/SPDF/App.class": b"\xca\xfe\xba\xbe",
            "BOOT-INF/classes/static/3rdPartyLicenses.json": CLEAN_BOM,
        })
        case("a clean jar passes", 0, clean, clean_sha, "PASS  the pinned jar is the MIT core")

        wrong_sha = root / "wrong-sha.jar"
        make_jar(wrong_sha, {
            "BOOT-INF/classes/static/3rdPartyLicenses.json": CLEAN_BOM,
        })
        case("a jar that is not the pin is refused", 1, wrong_sha,
             "0" * 64, "sha256 is not the pinned artefact")

        proprietary = root / "proprietary.jar"
        proprietary_sha = make_jar(proprietary, {
            "BOOT-INF/classes/static/3rdPartyLicenses.json": CLEAN_BOM,
            "BOOT-INF/classes/stirling/software/proprietary/security/LicenceService.class":
                b"\xca\xfe\xba\xbe",
        })
        case("a proprietary class is refused", 1, proprietary, proprietary_sha,
             "proprietary/saas entries")

        saas = root / "saas.jar"
        saas_sha = make_jar(saas, {
            "BOOT-INF/classes/static/3rdPartyLicenses.json": CLEAN_BOM,
            "BOOT-INF/classes/stirling/software/saas/Billing.class": b"\xca\xfe\xba\xbe",
        })
        case("a saas class is refused", 1, saas, saas_sha, "proprietary/saas entries")

        check = root / "licence-check.jar"
        check_sha = make_jar(check, {
            "BOOT-INF/classes/static/3rdPartyLicenses.json": CLEAN_BOM,
            "BOOT-INF/classes/stirling/software/SPDF/LicenceValidator.class":
                b"\xca\xfe\xba\xbe",
        })
        case("an unexpected licence-check class is refused", 1, check, check_sha,
             "licence-check class present")

        allowed = root / "allowed.jar"
        allowed_sha = make_jar(allowed, {
            "BOOT-INF/classes/static/3rdPartyLicenses.json": CLEAN_BOM,
            "BOOT-INF/classes/stirling/software/SPDF/controller/api/"
            "UIDataController$LicensesData.class": b"\xca\xfe\xba\xbe",
        })
        case("the UI licence-list record is allowed with a reason", 0, allowed, allowed_sha,
             "UI response record for the static third-party licence list")

        non_mit = root / "non-mit.jar"
        non_mit_sha = make_jar(non_mit, {
            "BOOT-INF/classes/static/3rdPartyLicenses.json": json.dumps({
                "dependencies": [
                    {"moduleName": "com.stirling:stirling-office-convert",
                     "moduleVersion": "0.3.3", "moduleLicense": "AGPL-3.0-only"},
                ],
                "importedModules": {},
            }).encode(),
        })
        case("a non-MIT com.stirling module is refused", 1, non_mit, non_mit_sha,
             "not MIT")

        nested = root / "nested.jar"
        nested_buffer = io.BytesIO()
        with zipfile.ZipFile(nested_buffer, "w") as inner:
            inner.writestr("stirling/software/proprietary/security/X.class",
                           b"\xca\xfe\xba\xbe")
        nested_sha = make_jar(nested, {
            "BOOT-INF/classes/static/3rdPartyLicenses.json": CLEAN_BOM,
            "BOOT-INF/lib/leak-1.0.jar": nested_buffer.getvalue(),
        })
        case("a proprietary class inside a nested library is refused", 1, nested,
             nested_sha, "proprietary/saas entries in nested jars")

    print()
    if failures:
        print(f"FAIL  {len(failures)} case(s) failed")
        return 1
    print("PASS  every rule of the licence scan refuses the dirty jar and passes the clean one")
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env python3
"""The licence and supply-chain scan of the pinned Stirling PDF server jar.

The jar is the MIT core artefact: the upstream `Stirling-PDF-server.jar` v3.3.0
release, reused as published. This script is the licence floor, and it is a
program rather than a paragraph so a rebuild is checked, not trusted.

It proves four claims and exits non-zero on any of them:

  1. the jar's sha256 is the pinned one;
  2. no class or resource lives under `stirling/software/proprietary/` or
     `stirling/software/saas/`, in the jar or in any nested library;
  3. no licence-check class is present — a class under `stirling/software/`
     whose name is about a licence, a subscription, billing or an entitlement
     is reported, and the only permitted match is the UI data holder that
     serves the static third-party licence list (`UIDataController$LicensesData`);
  4. every `com.stirling:*` module in the jar's own BOM (`static/3rdPartyLicenses.json`)
     is MIT.

Output is deterministic: no timestamps, no paths outside the jar itself. A run
on the same jar prints the same bytes, so a committed record can be compared.

Usage: licence_scan.py [--jar PATH] [--sha256 EXPECTED]
Exit: 0 every claim holds, 1 a claim failed, 2 the jar is unreadable.
"""

from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import sys
import zipfile

PINNED_SHA256 = "5cb59682f93bd7d48312d36a87585ef2e8ca9ddfa64bc210dea6bd882925557c"
PINNED_VERSION = "3.3.0"

PROPRIETARY_PATTERNS = (
    re.compile(r"(^|/)stirling/software/proprietary(/|$)"),
    re.compile(r"(^|/)stirling/software/saas(/|$)"),
)

# A class name that would carry a runtime licence gate: a licence/service key
# check, a subscription or billing gate, an entitlement check, or a paid-tier
# class. The pattern is deliberately broad — it reports every class under
# `stirling/software/` whose own name mentions the subject, and the allowlist
# below has to carry a reason for each one.
LICENCE_CHECK_NAME = re.compile(
    r"licen[cs]e|subscription|billing|entitlement|enterprise|paid|premium",
    re.IGNORECASE,
)

# The one allowed name match. It is a Spring MVC response record for the
# static third-party licence list (`GET /api/v1/info/...` UI data), not a
# check: `javap -p` shows a List<Dependency> field and getters/setters only.
# The proof document holds that javap output.
ALLOWED_NAME_MATCHES = {
    "BOOT-INF/classes/stirling/software/SPDF/controller/api/"
    "UIDataController$LicensesData.class": (
        "UI response record for the static third-party licence list; "
        "its class body is a List<Dependency> and getters/setters, no check"
    ),
}


def sha256_of(path: str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def nested_jars(jar: zipfile.ZipFile) -> list[str]:
    return sorted(
        name for name in jar.namelist()
        if name.startswith("BOOT-INF/lib/") and name.endswith(".jar")
    )


def scan_entries(entries: list[str], where: str, failures: list[str]) -> int:
    """Count proprietary/saas entries and collect licence-ish class names."""
    hits = [name for name in entries
            if any(pattern.search(name) for pattern in PROPRIETARY_PATTERNS)]
    if hits:
        failures.append(f"{where}: {len(hits)} proprietary/saas entries, first {hits[0]}")
    return len(hits)


def licence_name_matches(entries: list[str], where: str) -> list[str]:
    return sorted(
        name for name in entries
        if name.endswith(".class")
        and "/stirling/software/" in name
        and LICENCE_CHECK_NAME.search(name.rsplit("/", 1)[-1])
    )


def bom_modules(jar: zipfile.ZipFile) -> tuple[list[dict], str | None]:
    try:
        raw = jar.read("BOOT-INF/classes/static/3rdPartyLicenses.json")
    except KeyError:
        return [], "BOOT-INF/classes/static/3rdPartyLicenses.json is absent"
    document = json.loads(raw.decode("utf-8"))
    return list(document.get("dependencies") or []), None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--jar", default="app.jar", help="the Stirling server jar to scan")
    parser.add_argument("--sha256", default=PINNED_SHA256, help="the pinned sha256")
    args = parser.parse_args()

    try:
        jar = zipfile.ZipFile(args.jar)
    except (OSError, zipfile.BadZipFile) as error:
        print(f"FAIL  jar unreadable: {error}", file=sys.stderr)
        return 2

    failures: list[str] = []
    observed = sha256_of(args.jar)

    print("# Licence and supply-chain scan — Stirling-PDF-server.jar")
    print()
    print(f"jar:      {args.jar.rsplit('/', 1)[-1]}")
    print(f"sha256:   {observed}")
    print(f"expected: {args.sha256}")
    if observed != args.sha256:
        failures.append("the jar's sha256 is not the pinned artefact")

    manifest = jar.read("META-INF/MANIFEST.MF").decode("utf-8", "replace")
    version_match = re.search(r"^Implementation-Version:\s*(.+)$", manifest, re.M)
    version = version_match.group(1).strip() if version_match else "unknown"
    print(f"version:  {version}")
    if version != PINNED_VERSION:
        failures.append(f"Implementation-Version is {version}, the pin is {PINNED_VERSION}")

    names = jar.namelist()
    classes = [name for name in names if name.endswith(".class")]
    libs = nested_jars(jar)
    print(f"entries:  {len(names)}")
    print(f"classes:  {len(classes)}")
    print(f"libs:     {len(libs)}")
    print()

    # 1. proprietary and saas, in the jar and inside every nested library.
    print("## 1. Proprietary and SaaS classes")
    proprietary = scan_entries(names, "jar", failures)
    inner_proprietary = 0
    inner_scanned = 0
    for lib in libs:
        try:
            with zipfile.ZipFile(io.BytesIO(jar.read(lib))) as nested:
                inner_proprietary += scan_entries(nested.namelist(), lib, failures)
                inner_scanned += 1
        except zipfile.BadZipFile:
            failures.append(f"{lib}: not a readable jar")
    print(f"proprietary/saas entries in the jar:      {proprietary}")
    print(f"nested libraries scanned:                 {inner_scanned}")
    print(f"proprietary/saas entries in nested jars:  {inner_proprietary}")
    print("verdict:                                  "
          + ("PASS" if proprietary == 0 and inner_proprietary == 0 else "FAIL"))
    print()

    # 2. licence-check classes.
    print("## 2. Licence-check classes")
    name_matches = licence_name_matches(names, "jar")
    allowed = []
    unexpected = []
    for match in name_matches:
        if match in ALLOWED_NAME_MATCHES:
            allowed.append(match)
        else:
            unexpected.append(match)
    for name in allowed:
        print(f"allowed:  {name}")
        print(f"reason:   {ALLOWED_NAME_MATCHES[name]}")
    for name in unexpected:
        print(f"unexpected: {name}")
        failures.append(f"licence-check class present: {name}")
    print(f"name matches:   {len(name_matches)}")
    print(f"allowed:        {len(allowed)}")
    print(f"unexpected:     {len(unexpected)}")
    print("verdict:        " + ("PASS" if not unexpected else "FAIL"))
    print()

    # 3. the jar's own BOM: every com.stirling module must be MIT.
    print("## 3. com.stirling:* modules in the jar's own BOM")
    modules, bom_error = bom_modules(jar)
    if bom_error:
        failures.append(bom_error)
        print(f"BOM: {bom_error}")
    stirling_modules = [
        module for module in modules
        if str(module.get("moduleName", "")).startswith("com.stirling:")
    ]
    versions = {}
    for module in stirling_modules:
        name = module.get("moduleName")
        license_name = module.get("moduleLicense")
        versions[name] = module.get("moduleVersion")
        print(f"{name}: {module.get('moduleVersion')} — {license_name}")
        if license_name != "MIT License":
            failures.append(f"{name} is {license_name}, not MIT")
    print(f"com.stirling modules: {len(stirling_modules)}")
    print(f"all MIT:              "
          + ("YES" if stirling_modules and all(
              module.get("moduleLicense") == "MIT License" for module in stirling_modules
          ) else "NO"))
    if not stirling_modules:
        failures.append("no com.stirling module in the BOM")

    # The BOM names the modules; the jar names the artefacts it actually ships.
    # A version skew is recorded, never hidden: MIT does not depend on it, but a
    # reader must see which bytes ran.
    print()
    print("### Shipped vs declared versions")
    nested_by_module = {}
    for lib in libs:
        base = lib.rsplit("/", 1)[-1]
        for module_name in versions:
            artifact = module_name.split(":", 1)[1]
            if re.fullmatch(re.escape(artifact) + r"-[0-9][^/]*\.jar", base):
                nested_by_module[module_name] = base
    for module_name in sorted(versions):
        shipped = nested_by_module.get(module_name, "(not in the fat jar)")
        print(f"{module_name}: BOM {versions[module_name]}, jar {shipped}")
    print()

    print("## Verdict")
    if failures:
        for failure in failures:
            print(f"FAIL  {failure}")
        return 1
    print("PASS  the pinned jar is the MIT core: no proprietary or SaaS classes, "
          "no licence-check class, every com.stirling module MIT.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

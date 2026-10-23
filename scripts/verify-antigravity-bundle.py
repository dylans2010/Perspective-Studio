#!/usr/bin/env python3
"""Verify the Antigravity SDK is actually bundled into the Locally app.

The SDK must reach the built app as ONE folder reference copied into
Contents/Resources/AntigravitySDK/ with its directory structure intact.
The project uses a file-system synchronized group for Locally/, which
flattens loose resources into the bundle root (and collides on the SDK's
many __init__.py files), so the vendored files are membership-excepted
from the synchronized group and shipped via the explicit folder
reference instead. This script fails if either half of that wiring is
missing, if the vendored tree drifts from sdk-manifest.json, or if the
SDK's compiled localharness runtime sneaks back in (loop-only policy).

Usage: python3 scripts/verify-antigravity-bundle.py
Exit code 0 = bundled correctly.
"""
import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PBXPROJ = os.path.join(ROOT, "Locally.xcodeproj", "project.pbxproj")
SDK_DIR = os.path.join(ROOT, "Locally", "AntigravitySDK")

failures = []


def check(condition, message):
    if condition:
        print(f"  ok  {message}")
    else:
        failures.append(message)
        print(f"FAIL  {message}")


def main():
    pbx = open(PBXPROJ, encoding="utf-8").read()

    print("== Xcode project wiring ==")
    fileref = re.search(
        r"(\w{24}) /\* AntigravitySDK \*/ = \{isa = PBXFileReference;[^}]*"
        r"lastKnownFileType = folder;[^}]*path = \"Locally/AntigravitySDK\"",
        pbx,
    )
    check(fileref is not None,
          "PBXFileReference folder entry for Locally/AntigravitySDK exists")
    buildfile = re.search(
        r"(\w{24}) /\* AntigravitySDK in Resources \*/ = \{isa = PBXBuildFile; "
        r"fileRef = (\w{24}) /\* AntigravitySDK \*/; \}",
        pbx,
    )
    check(buildfile is not None, "PBXBuildFile 'AntigravitySDK in Resources' exists")
    if fileref and buildfile:
        check(buildfile.group(2) == fileref.group(1),
              "BuildFile points at the folder FileReference")
    # The Resources phase of the Locally target must reference the build file.
    resources = re.search(
        r"9DE341F42F59134300242AA7 /\* Resources \*/ = \{[^}]*?files = \(([^)]*)\)",
        pbx, re.S)
    check(resources is not None and buildfile is not None
          and buildfile.group(1) in resources.group(1),
          "Locally target Resources phase contains the SDK build file")

    print("== Synchronized-group exceptions ==")
    exceptions = re.findall(r"AntigravitySDK/([^\s,;]+\.py|sdk-manifest\.json|LICENSE|BUNDLED\.md|google_antigravity-0\.1\.20\.dist-info/METADATA)", pbx)
    check(len(exceptions) >= 60,
          f"membership exceptions exclude the vendored files from flattening ({len(exceptions)} found)")

    print("== Vendored tree vs manifest ==")
    manifest = json.load(open(os.path.join(SDK_DIR, "sdk-manifest.json")))
    for entry in manifest["files"]:
        path = os.path.join(SDK_DIR, entry["path"])
        if not os.path.isfile(path):
            check(False, f"manifest file present: {entry['path']}")
            continue
        data = open(path, "rb").read()
        ok = (len(data) == entry["bytes"]
              and hashlib.sha256(data).hexdigest() == entry["sha256"])
        if not ok:
            check(False, f"integrity: {entry['path']}")
    print(f"  ok  {len(manifest['files'])} manifest files verified")

    print("== Loop-only policy ==")
    harness = []
    for dirpath, _dirs, files in os.walk(SDK_DIR):
        for name in files:
            if name == "localharness" or name.startswith("localharness."):
                harness.append(os.path.join(dirpath, name))
    check(not harness, "no compiled localharness runtime in the vendored tree")

    if failures:
        print(f"\n{len(failures)} problem(s): the Antigravity SDK is NOT correctly bundled.")
        return 1
    print("\nAntigravity SDK bundling is correct: folder reference -> Resources, "
          "exceptions prevent flattening, manifest intact, loop-only.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

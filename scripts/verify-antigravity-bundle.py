#!/usr/bin/env python3
"""Verify the Antigravity SDK is actually bundled into the Locally app.

The SDK must reach the built app as a complete directory tree at
Contents/Resources/AntigravitySDK/. The project uses a file-system
synchronized group for Locally/, which flattens loose resources into
the bundle root (and collides on the SDK's many __init__.py files), so
the vendored files are membership-excepted from the synchronized group
and copied instead by a dedicated "Bundle Antigravity SDK" Run Script
build phase (ditto, manifest-gated, fails the build if the copy is
incomplete). This script fails if either half of that wiring is
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
    phase = re.search(
        r"(\w{24}) /\* Bundle Antigravity SDK \*/ = \{\s*isa = PBXShellScriptBuildPhase;",
        pbx,
    )
    check(phase is not None, "'Bundle Antigravity SDK' shell-script phase exists")
    if phase:
        pid = phase.group(1)
        target = re.search(
            r"9DE341F52F59134300242AA7 /\* Locally \*/ = \{.*?buildPhases = \(([^)]*)\)",
            pbx, re.S)
        check(target is not None and pid in target.group(1),
              "script phase is in the Locally target's build phases")
        check("Locally/AntigravitySDK" in pbx and "ditto" in pbx,
              "script copies Locally/AntigravitySDK with ditto")
        check("sdk-manifest.json" in pbx,
              "script is gated on the SDK manifest")
        check("Contents/Resources/AntigravitySDK" in pbx.replace("$(TARGET_BUILD_DIR)/$(CONTENTS_FOLDER_PATH)/Resources/AntigravitySDK", "Contents/Resources/AntigravitySDK"),
              "script destination is the app bundle's Resources/AntigravitySDK")

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

    print("== Locally strip: no Google model content in hand-written sources ==")
    # The vendored hand-written Python was stripped of Google's model
    # layer (models, model connections, built-in tool definitions,
    # default system instructions): models, tools, and system prompts
    # are Locally's own, served from its context index. Generated proto
    # descriptors (proto/*_pb2.py) are inert and explicitly excluded —
    # they embed genai type names by construction and are never edited
    # by hand. If Google model content returns to a hand-written file,
    # this check fails loudly.
    strip_offenders = []
    for dirpath, _dirs, files in os.walk(SDK_DIR):
        for name in files:
            if not name.endswith(".py"):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, SDK_DIR)
            if "_pb2.py" in name or os.sep + "proto" + os.sep in path:
                continue
            text = open(path, encoding="utf-8").read()
            if re.search(r"gemini-\d", text) or "DEFAULT_MODEL" in text:
                strip_offenders.append(rel)
    check(not strip_offenders,
          "no Google model strings (gemini-*, DEFAULT_MODEL) in hand-written .py"
          + (f" — offenders: {', '.join(strip_offenders)}" if strip_offenders else ""))

    if failures:
        print(f"\n{len(failures)} problem(s): the Antigravity SDK is NOT correctly bundled.")
        return 1
    print("\nAntigravity SDK bundling is correct: script phase -> Resources, "
          "exceptions prevent flattening, manifest intact, loop-only.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

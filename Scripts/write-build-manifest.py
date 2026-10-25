#!/usr/bin/env python3
"""Write build provenance without recording local paths or signing identities."""

import argparse
import hashlib
import json
import plistlib
import re
import subprocess
from pathlib import Path


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path)
    parser.add_argument("app", type=Path)
    args = parser.parse_args()
    version = (args.project / "VERSION").read_text().strip()
    build = (args.project / "BUILD_NUMBER").read_text().strip()
    upstream = (args.project / "Core/UPSTREAM_REVISION").read_text().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not re.fullmatch(r"[1-9]\d*", build):
        parser.error("VERSION must be x.y.z and BUILD_NUMBER must be a positive integer")
    if not re.fullmatch(r"[0-9a-f]{40}", upstream):
        parser.error("Core/UPSTREAM_REVISION must identify the pinned upstream commit")
    info = plistlib.loads((args.app / "Contents/Info.plist").read_bytes())
    if (info["CFBundleShortVersionString"], info["CFBundleVersion"]) != (version, build):
        parser.error("application version does not match source version files")
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=args.project,
                              capture_output=True, text=True)
    source_revision = revision.stdout.strip() if revision.returncode == 0 else None
    status = subprocess.run(["git", "status", "--porcelain", "--untracked-files=normal"],
                            cwd=args.project, capture_output=True, text=True)
    dirty = bool(status.stdout.strip()) if status.returncode == 0 else None
    helpers = args.app / "Contents/Helpers"
    core = helpers / "minieasyconnect-core"
    core_info = subprocess.check_output(["go", "version", "-m", str(core)], text=True)
    toolchain = core_info.splitlines()[0].rsplit(": ", 1)[1]
    manifest = {
        "schemaVersion": 1,
        "applicationVersion": version,
        "buildNumber": build,
        "sourceRevision": source_revision,
        "sourceHasLocalChanges": dirty,
        "upstreamRevision": upstream,
        "target": "darwin/arm64",
        "goToolchain": toolchain,
        "embeddedExecutablesSHA256": {
            name: sha256(helpers / name)
            for name in ("miniEasyConnectHelper", "minieasyconnect-core")
        },
    }
    destination = args.app / "Contents/Resources/BuildManifest.json"
    destination.write_text(json.dumps(manifest, indent=2) + "\n")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Reject stale or incomplete hashes for the shared first-party C core."""

import hashlib
import json
from pathlib import Path
import re
import sys


def validate(root: Path) -> None:
    manifest = json.loads((root / "source-hashes.json").read_text())
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 2:
        raise ValueError("source-hashes.json requires schema_version 2 with shared_c and swift_module groups")
    if set(manifest) != {"schema_version", "shared_c", "swift_module"}:
        raise ValueError("unexpected source-hashes.json fields")
    shared = {str(path.relative_to(root)) for pattern in ("*.c", "include/thalovant/**/*.h")
              for path in root.glob(pattern)}
    headers = {str(path.relative_to(root)) for path in root.glob("include/**/*.h")}
    expected_groups = {"shared_c": shared, "swift_module": headers - shared}
    hashes = {}
    for group, sources in expected_groups.items():
        entries = manifest[group]
        if not isinstance(entries, dict) or not entries:
            raise ValueError(f"{group} must be a nonempty object")
        if set(entries) != sources:
            raise ValueError(f"{group} source file list differs: missing={sorted(sources - set(entries))}, "
                             f"extra={sorted(set(entries) - sources)}")
        hashes.update(entries)
    for name, expected in hashes.items():
        path = root / name
        if path.is_symlink() or not path.is_file() or not path.resolve().is_relative_to(root.resolve()):
            raise ValueError(f"source is not a regular in-tree file: {name}")
        if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise ValueError(f"invalid SHA256 for {name}")
        actual = hashlib.sha256(path.read_bytes()).hexdigest()
        if actual != expected:
            raise ValueError(f"SHA256 mismatch for {name}: expected {expected}, got {actual}")


if __name__ == "__main__":
    core = Path(__file__).resolve().parents[1] / "Sources/CThalovantNoise"
    try:
        validate(core)
    except (OSError, ValueError) as error:
        print(f"First-party C provenance check failed: {error}", file=sys.stderr)
        raise SystemExit(1)
    print("Source hashes match every shared C source/header and Swift module header.")

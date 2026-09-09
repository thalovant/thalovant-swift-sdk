#!/usr/bin/env python3
"""Reject stale or incomplete hashes for the shared first-party C core."""

import hashlib
import json
from pathlib import Path
import re
import sys


def validate(root: Path) -> None:
    hashes = json.loads((root / "source-hashes.json").read_text())
    if not isinstance(hashes, dict) or not hashes:
        raise ValueError("source-hashes.json must be a nonempty object")
    sources = {str(path.relative_to(root)) for pattern in ("*.c", "include/thalovant/*.h")
               for path in root.glob(pattern)}
    if set(hashes) != sources:
        raise ValueError(f"source file list differs: missing={sorted(sources - set(hashes))}, "
                         f"extra={sorted(set(hashes) - sources)}")
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
    print("First-party C source hashes match every shared source and header.")

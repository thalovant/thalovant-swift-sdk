"""Prove the release provenance check fails on drift and missing entries."""

import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("source_hashes", Path(__file__).parents[1] / "check-source-hashes.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class SourceHashTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "include/thalovant").mkdir(parents=True)
        self.hashes = {}
        self.wrapper = "include/CThalovantNoise.h"
        for name in ("noise.c", "include/thalovant/noise.h", self.wrapper):
            (self.root / name).write_text("/* synthetic fixture */\n")
            self.hashes[name] = hashlib.sha256((self.root / name).read_bytes()).hexdigest()
        self.write_manifest()

    def write_manifest(self):
        manifest = {"schema_version": 2,
                    "shared_c": {k: v for k, v in self.hashes.items() if k != self.wrapper},
                    "swift_module": {k: v for k, v in self.hashes.items() if k == self.wrapper}}
        (self.root / "source-hashes.json").write_text(json.dumps(manifest))

    def test_complete_copy_passes(self):
        checker.validate(self.root)

    def test_changed_source_fails(self):
        (self.root / "noise.c").write_text("/* changed source */\n")
        with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
            checker.validate(self.root)

    def test_changed_umbrella_header_fails(self):
        (self.root / self.wrapper).write_text("/* changed public umbrella */\n")
        with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
            checker.validate(self.root)

    def test_old_ungrouped_manifest_requires_explicit_migration(self):
        (self.root / "source-hashes.json").write_text(json.dumps(self.hashes))
        with self.assertRaisesRegex(ValueError, "schema_version 2"):
            checker.validate(self.root)

    def test_umbrella_cannot_be_mislabelled_shared(self):
        path = self.root / "source-hashes.json"
        manifest = json.loads(path.read_text())
        manifest["shared_c"].update(manifest["swift_module"])
        manifest["swift_module"] = {}
        path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "shared_c source file list differs"):
            checker.validate(self.root)

    def test_dropped_manifest_entry_fails(self):
        self.hashes.pop("noise.c")
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "source file list differs"):
            checker.validate(self.root)

    def test_missing_source_fails(self):
        (self.root / "noise.c").unlink()
        with self.assertRaisesRegex(ValueError, "source file list differs"):
            checker.validate(self.root)

    def test_outside_tree_entry_fails(self):
        self.hashes["../outside.c"] = "0" * 64
        self.write_manifest()
        with self.assertRaisesRegex(ValueError, "source file list differs"):
            checker.validate(self.root)

    def test_symlink_source_fails(self):
        (self.root / "noise.c").unlink()
        (self.root / "noise.c").symlink_to(self.root / "include/thalovant/noise.h")
        with self.assertRaisesRegex(ValueError, "regular in-tree file"):
            checker.validate(self.root)


if __name__ == "__main__":
    unittest.main()

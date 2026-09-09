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
        for name in ("noise.c", "include/thalovant/noise.h"):
            (self.root / name).write_text("/* synthetic fixture */\n")
            self.hashes[name] = hashlib.sha256((self.root / name).read_bytes()).hexdigest()
        self.write_manifest()

    def write_manifest(self):
        (self.root / "source-hashes.json").write_text(json.dumps(self.hashes))

    def test_complete_copy_passes(self):
        checker.validate(self.root)

    def test_changed_source_fails(self):
        (self.root / "noise.c").write_text("/* changed source */\n")
        with self.assertRaisesRegex(ValueError, "SHA256 mismatch"):
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

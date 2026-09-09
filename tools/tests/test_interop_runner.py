"""Exercise failure diagnostics without compiling code or opening a socket."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class InteropRunnerTests(unittest.TestCase):
    def run_fixture(self, swift_status: int, peer_status: int | None):
        with tempfile.TemporaryDirectory() as directory:
            commands = Path(directory)
            swift = commands / "swift"
            swift.write_text(f'#!/usr/bin/env bash\nif [[ "$1" == "build" ]]; then exit 0; fi\nexit {swift_status}\n')
            node = commands / "node"
            finish = "signal.pause()" if peer_status is None else f"time.sleep(0.3)\nsys.exit({peer_status})"
            node.write_text('#!/usr/bin/env python3\nimport signal,sys,time\n'
                            'print("ws://127.0.0.1:1", flush=True)\n'
                            'print("synthetic peer diagnostic", flush=True)\n' + finish + '\n')
            swift.chmod(0o755)
            node.chmod(0o755)
            runner = Path(__file__).resolve().parents[1] / "interop/run.sh"
            return subprocess.run(["bash", str(runner), str(commands)],
                                  env={**os.environ, "PATH": str(commands) + os.pathsep + os.environ["PATH"]},
                                  capture_output=True, text=True, timeout=10)

    def test_swift_failure_preserves_peer_log_and_exit_status(self):
        result = self.run_fixture(23, None)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertIn("synthetic peer diagnostic", result.stdout)

    def test_peer_failure_preserves_peer_log_and_exit_status(self):
        result = self.run_fixture(0, 7)
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertIn("synthetic peer diagnostic", result.stdout)


if __name__ == "__main__":
    unittest.main()

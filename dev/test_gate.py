#!/usr/bin/env python3
"""Exercise warning rejection and fail-closed test-output validation."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

from gate import native_command, test_count


class GateTests(unittest.TestCase):
    def test_accepts_real_nonempty_gleeunit_summary(self):
        self.assertEqual(
            test_count("\x1b[32m.\n134 passed, no failures\x1b[39m\n"), 134
        )

    def test_rejects_empty_missing_failed_and_ambiguous_results(self):
        for output in [
            "",
            "Compiled successfully",
            "0 passed, no failures",
            "No tests found!",
            "134 passed, 1 failures",
            "134 passed, 0 failures, 1 skipped",
            "134 passed, no failures\n134 passed, no failures",
        ]:
            with self.subTest(output=output), self.assertRaises(ValueError):
                test_count(output)

    def test_native_warning_rejection_and_positive_control(self):
        with tempfile.TemporaryDirectory(prefix="sinal-native-control-") as directory:
            root = Path(directory)
            source = root / "src"
            source.mkdir()
            output = root / "output"
            output.mkdir()
            control = source / "gate_control.erl"
            control.write_text(
                "-module(gate_control).\n-export([value/0]).\nvalue() -> ok.\n"
            )
            accepted = subprocess.run(
                native_command(root, output),
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(accepted.returncode, 0, accepted.stdout + accepted.stderr)
            self.assertTrue((output / "gate_control.beam").exists())
            (output / "gate_control.beam").unlink()
            control.write_text(
                "-module(gate_control).\n-export([value/0]).\nvalue() -> Unused = 1, ok.\n"
            )
            rejected = subprocess.run(
                native_command(root, output),
                capture_output=True,
                text=True,
                check=False,
            )
            diagnostic = rejected.stdout + rejected.stderr
            self.assertNotEqual(rejected.returncode, 0, diagnostic)
            self.assertIn("variable 'Unused' is unused", diagnostic)
            self.assertFalse((output / "gate_control.beam").exists())

    def test_cli_fails_and_retains_evidence_when_a_command_fails(self):
        with tempfile.TemporaryDirectory(prefix="sinal-gate-failure-") as directory:
            root = Path(directory)
            binary = root / "gleam"
            binary.write_text(f"#!{sys.executable}\nraise SystemExit(3)\n")
            binary.chmod(0o755)
            artifacts = root / "evidence"
            rejected = subprocess.run(
                [
                    sys.executable,
                    str(Path(__file__).with_name("gate.py")),
                    "fast",
                    "--artifacts",
                    str(artifacts),
                ],
                env={**os.environ, "PATH": str(root)},
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(rejected.returncode, 1, rejected.stdout + rejected.stderr)
            summary = json.loads((artifacts / "summary.json").read_text())
            self.assertEqual(summary["result"], "failure")
            self.assertEqual(summary["checks"][0]["exit_code"], 3)
            self.assertEqual(len(summary["checks"]), 1)
            self.assertTrue((artifacts / "gleam-version.log").exists())

    def test_rejects_missing_native_sources(self):
        with tempfile.TemporaryDirectory(prefix="sinal-native-empty-") as directory:
            root = Path(directory)
            with self.assertRaises(ValueError):
                native_command(root, root)


if __name__ == "__main__":
    unittest.main(verbosity=2)

#!/usr/bin/env python3
"""Run Sinal validation and retain each command's output separately."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent.parent
ANSI = re.compile(r"\x1b\[[0-9;]*m")


def test_count(output: str) -> int:
    """Require the nonempty successful summary emitted by pinned Gleeunit."""
    summaries = re.findall(
        r"^\s*(\d+) passed, no failures\s*$", ANSI.sub("", output), re.MULTILINE
    )
    if len(summaries) != 1 or int(summaries[0]) == 0:
        raise ValueError("missing, ambiguous or empty successful Gleeunit summary")
    return int(summaries[0])


def native_command(root: Path, output: Path) -> list[str]:
    """Compile authored Erlang, including the temporary race probe, independently."""
    sources = sorted(root.glob("src/**/*.erl")) + sorted(root.glob("test/**/*.erl"))
    for asset in sorted(root.glob("dev/*.erl.txt")):
        copied = output / asset.name.removesuffix(".txt")
        shutil.copyfile(asset, copied)
        sources.append(copied)
    if not sources:
        raise ValueError("no authored Erlang sources found")
    command = ["erlc", "-Werror", "-o", str(output)]
    for pattern, option in [
        ("build/packages/*/include", "-I"),
        ("build/dev/erlang/*/include", "-I"),
        ("build/dev/erlang/*/ebin", "-pa"),
    ]:
        for directory in sorted(root.glob(pattern)):
            command.extend([option, str(directory)])
    return command + [str(source) for source in sources]


class Evidence:
    def __init__(self, directory: Path, profile: str):
        directory.mkdir(parents=True, exist_ok=True)
        self.directory = directory
        self.summary = {"profile": profile, "checks": [], "result": "running"}

    def run(self, name: str, command: list[str], timeout: int = 300) -> str:
        started = time.monotonic()
        log = self.directory / f"{name}.log"
        record = {"name": name, "command": command, "log": log.name}
        self.summary["checks"].append(record)
        print(f"\nChecking {name}: {' '.join(command)}", flush=True)
        try:
            with log.open("w") as stream:
                result = subprocess.run(
                    command,
                    cwd=ROOT,
                    stdout=stream,
                    stderr=subprocess.STDOUT,
                    timeout=timeout,
                    check=False,
                )
            output = log.read_text()
            print(output, end="", flush=True)
            record["exit_code"] = result.returncode
            if result.returncode != 0:
                raise RuntimeError(f"{name} exited {result.returncode}; see {log}")
            return output
        finally:
            record["elapsed_seconds"] = round(time.monotonic() - started, 3)

    def save(self):
        (self.directory / "summary.json").write_text(
            json.dumps(self.summary, indent=2) + "\n"
        )


def source_hashes() -> dict[str, str]:
    sources = sorted(ROOT.glob("src/**/*.gleam")) + sorted(ROOT.glob("src/**/*.erl"))
    sources += [
        ROOT / name
        for name in [
            "test/benchmark.gleam",
            "gleam.toml",
            "manifest.toml",
            "flake.lock",
        ]
    ]
    return {
        str(path.relative_to(ROOT)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sources
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("profile", choices=["fast", "full", "benchmark"])
    parser.add_argument("--artifacts", type=Path, default=ROOT / ".artifacts/gate")
    args = parser.parse_args()
    evidence = Evidence(args.artifacts.resolve(), args.profile)
    try:
        evidence.run("gleam-version", ["gleam", "--version"])
        if args.profile != "benchmark":
            evidence.run(
                "nix-checks", ["nix", "flake", "check", "--print-build-logs"], 600
            )
            evidence.run("gleam-format", ["gleam", "format", "--check", "src", "test"])
        if args.profile == "full":
            evidence.run("clean-build", ["gleam", "clean"])
        evidence.run("gleam-build", ["gleam", "build", "--warnings-as-errors"])
        with tempfile.TemporaryDirectory(prefix="sinal-native-") as directory:
            evidence.run("native-build", native_command(ROOT, Path(directory)))
        if args.profile == "benchmark":
            evidence.summary["source_sha256"] = source_hashes()
            evidence.run("benchmark", ["gleam", "run", "-m", "benchmark"])
        else:
            evidence.run("gate-controls", ["python3", "dev/test_gate.py"])
            output = evidence.run("package-tests", ["gleam", "test"])
            evidence.summary["passed_tests"] = test_count(output)
            if args.profile == "full":
                evidence.run(
                    "focused-native", ["gleam", "run", "-m", "focused_behavior"]
                )
                evidence.run("native-stress", ["gleam", "run", "-m", "stress_test"])
                evidence.run("forwarder-races", ["python3", "dev/check_forwarder.py"])
                evidence.run(
                    "design",
                    ["nix", "run", ".#design-gate-check", "--", "docs/design", "."],
                    600,
                )
        evidence.summary["result"] = "success"
        return 0
    except (OSError, RuntimeError, ValueError, subprocess.TimeoutExpired) as error:
        evidence.summary["result"] = "failure"
        evidence.summary["error"] = str(error)
        print(f"Gate failed: {error}", flush=True)
        return 1
    finally:
        evidence.save()


if __name__ == "__main__":
    raise SystemExit(main())

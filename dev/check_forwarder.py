#!/usr/bin/env python3
"""Synchronize startup, delayed-event and delayed-drop races in an isolated source copy.

No production test seam: instrumentation is applied only in the temporary copy.
Requires gleam/OTP on PATH. --source selects an original or candidate checkout.
"""

import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument(
    "--source", type=Path, default=Path(__file__).resolve().parent.parent
)
parser.add_argument(
    "--scenario",
    choices=["all", "startup", "delayed_sender", "delayed_drop"],
    default="all",
)
args = parser.parse_args()
assets = Path(__file__).resolve().parent
with tempfile.TemporaryDirectory(prefix="sinal-forwarder-race-") as directory:
    work = Path(directory)
    for name in ["src", "gleam.toml", "manifest.toml"]:
        source = args.source / name
        if source.is_dir():
            shutil.copytree(source, work / name)
        else:
            shutil.copy2(source, work / name)
    cache = args.source / "build/packages"
    if cache.exists():
        shutil.copytree(cache, work / "build/packages")
    target = work / "src/sinal/forwarder.gleam"
    text = target.read_text()
    anchor = "actor.new_with_initialiser(1000, fn(subject) {"
    assert text.count(anchor) == 1
    text = text.replace(anchor, anchor + "\n    probe_before_start()")
    start = text.index("fn forward(")
    end = text.index("/// Increments a drop slot", start)
    body = text[start:end]
    assert body.count("process.send(") == 1
    body = body.replace(
        "process.send(", "probe_before_send()\n          process.send(", 1
    )
    text = text[:start] + body + text[end:]
    start = text.index("fn report_drop(")
    body = text[start:]
    assert body.count("process.send(") == 1
    body = body.replace("process.send(", "probe_drop_send(", 1)
    text = text[:start] + body
    text += '\n@external(erlang, "restart_probe_ffi", "before_drop")\nfn probe_before_drop() -> Nil\n'
    text += "\nfn probe_drop_send(subject: process.Subject(Message), message: Message) -> Nil { probe_before_drop() process.send(subject, message) }\n"
    text += '\n@external(erlang, "restart_probe_ffi", "before_start")\nfn probe_before_start() -> Nil\n'
    text += '\n@external(erlang, "restart_probe_ffi", "before_send")\nfn probe_before_send() -> Nil\n'
    target.write_text(text)
    for filename in ["restart_probe.gleam", "restart_probe_ffi.erl"]:
        shutil.copy2(assets / (filename + ".txt"), work / "src" / filename)
    if args.scenario != "all":
        probe = work / "src/restart_probe.gleam"
        content = probe.read_text()
        for other in ["startup", "delayed_sender", "delayed_drop"]:
            if other != args.scenario:
                content = content.replace("  " + other + "()\n", "")
        probe.write_text(content)
    code = subprocess.run(
        ["gleam", "run", "-m", "restart_probe"], cwd=work, timeout=60
    ).returncode
    raise SystemExit(code)

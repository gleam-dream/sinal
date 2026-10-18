# Agent Instructions

`sinal` emits and observes typed telemetry through native Erlang `:telemetry`. The design layer in `docs/design/` is the source of truth for behavior; `README.md` is the consumer entry point.

## Tooling

- `nix develop` (or direnv): dev shell with `gleam`, Erlang/OTP 29, `rebar3`, Python and `lefthook`. Run every command from the package root, or prefix it with `nix develop --command`.
- `nix fmt`: formats the whole repo via treefmt (`gleam format`, `nixfmt`, `prettier`, Ruff for `dev/*.py`).
- `lefthook`: the pre-commit hook formats staged files, re-stages them and runs the design gate.

## Validation

- `python3 dev/gate.py fast`: formatting, tooling lint, Gleam build, independent `erlc -Werror` native build, gate controls and `gleam test`.
- `python3 dev/gate.py full`: the fast checks on a clean build plus the focused native, stress and forwarder race checks and the design gate. CI runs this profile.
- `python3 dev/gate.py benchmark --artifacts .artifacts/benchmark`: the benchmark program with retained output and source hashes.
- `cd examples/usage && gleam build --warnings-as-errors && gleam test` (and `gleam run`): the compiled usage examples; both gate profiles run them after the package tests.
- `gleam build --warnings-as-errors`, `gleam test`, `nix flake check --print-build-logs` and `git diff --check`: the individual checks behind the profiles.
- `gleam run -m focused_behavior`, `gleam run -m stress_test`, `python3 dev/check_forwarder.py` (with `--scenario startup`, `delayed_sender` or `delayed_drop`) and `python3 dev/test_gate.py`: the native checks and gate controls.
- Design change: render and check the layer with the commands in the design gate block below, and read the rendered document, because a passing gate does not prove semantic fidelity.

## Constraints

- Event names, route prefixes and field keys must come from source, because each creates a permanent atom.
- README Gleam snippets must occur verbatim in `examples/usage/src/usage/*.gleam`; `test/readme_example_test.gleam` checks them and asserts the snippet count, so change the README and the example together. Usage documentation lives in those compiled examples, not in prose guides.
- Synchronization barriers, not sleeps, establish race ordering in tests.
- Benchmark output is observation; no test asserts a latency threshold.

## References

- [docs/ORACLE.md](docs/ORACLE.md): the pinned native `telemetry` 1.4.2 reference that Sinal's native behavior is compared against, with the case mapping, deliberate differences and how to rerun it.
- [docs/BENCHMARKS.md](docs/BENCHMARKS.md): the benchmark method, how to run it and the retained dated run; observation only, with no performance guarantee.
- [examples/usage](examples/usage/README.md): compiled, runnable usage examples that keep the README current.

<!-- agent-skills:begin -->
<!-- framework-commit: cab7c0590036edaa66d8430cc5016399a9fd2c71 origin: git@github.com:lostbean/skills.git -->

(machine-owned; do not edit inside this fence — re-run setup to refresh)

## Agent skills

**Design layer** — the design document is `docs/design/design.typ` (the layer
renders to one `docs/design/design-layer.pdf`); `docs/CONTEXT-MAP.md` indexes
the contexts, each context's `CONTEXT.typ` defines its terms, and decisions are
recorded in `docs/adr/`. `docs/COVERAGE.md` maps repository parts to their
design owners.

**Tracker** — local markdown under `issues/`: one directory per feature
(`issues/<feature-slug>/`), the PRD at `issues/<feature-slug>/PRD.md`, issue
files at `issues/<feature-slug>/issues/<NN>-<slug>.md` numbered from 01. Each
issue file carries two header lines near the top — `Status: <state>`,
`Category: <category>`. Conversation appends to the bottom
of the file under a `## Comments` heading. Labels (canonical strings, adopted
verbatim): states `needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `in-progress`, `done`, `wontfix`; categories `bug`,
`enhancement`.

**AI disclaimer** — AI-authored tracker comments start with
`AI-assisted contribution.`

**Design gate** — `nix run .#design-gate-check -- docs/design .` checks render freshness,
vocabulary references and layer integrity (exit 0 clean, 1 violation, 2 error).
The gate is supplied by the pinned `design-layer` flake input.
`nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf`
rebuilds the rendered document. `nix run .#design-gate-context -- docs/design --estimate`
estimates agent context; the same command without `--estimate` emits ephemeral
Markdown. `--manifest`, `--preview`, and `--section PATH --expect-digest DIGEST`
support loading selected sections. A bare Typst compilation does not run the gate.

**Context verification** — use native semantic blocks for lists, tables,
models and behavior. After authoring, verify context estimation and a selected
section export as well as rendering and the design gate.
Run these commands sequentially for each layer; they share its generated
`.render` workspace.

**Staleness** — source changes since the design last changed require a
conformance review before the layer is treated as current.

<!-- agent-skills:end -->

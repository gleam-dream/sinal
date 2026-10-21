# Agent Instructions

`sinal` emits and observes typed telemetry through native Erlang `:telemetry`. The design layer in `docs/design/` is the source of truth for behavior; `README.md` is the consumer entry point.

## Tooling

- `nix develop` (or direnv): dev shell with `gleam`, Erlang/OTP 29, `rebar3`, Python and `lefthook`. Run every command from the package root, or prefix it with `nix develop --command`.
- `nix fmt`: formats the whole repo via treefmt (`gleam format`, `nixfmt`, `prettier`, Ruff for `dev/*.py`).
- `lefthook`: the pre-commit hook formats staged files, re-stages them.

## Validation

- `sh dev/test fast`: Gleam build, independent `erlc -Werror` native build and `gleam test`.
- `sh dev/test full`: the fast checks plus the focused native, stress and forwarder race checks. CI runs this profile.
- `gleam run -m benchmark`: the optional benchmark program.
- `cd examples/usage && gleam build --warnings-as-errors && gleam test` (and `gleam run`): the compiled usage examples; both gate profiles run them after the package tests.
- `nix fmt` formats; CI calls `nix flake check` and the imported design check directly. `sh dev/test` only builds and runs tests.
- `gleam run -m focused_behavior`, `gleam run -m stress_test`, `python3 dev/check_forwarder.py` (with `--scenario startup`, `delayed_sender` or `delayed_drop`): the native checks.
- After design changes, render and run the imported design check.

## Constraints

- Event names, route prefixes and field keys must come from source, because each creates a permanent atom.
- Usage examples in `examples/usage` compile and run. README code excerpts are synchronized from tested sources with Snips.
- Synchronization barriers, not sleeps, establish race ordering in tests.
- Benchmark output is observation; no test asserts a latency threshold.

## References

- [docs/ORACLE.md](docs/ORACLE.md): the pinned native `telemetry` 1.4.2 reference that Sinal's native behavior is compared against, with the case mapping, deliberate differences and how to rerun it.
- [docs/BENCHMARKS.md](docs/BENCHMARKS.md): the benchmark method, how to run it and the retained dated run; observation only, with no performance guarantee.
- [examples/usage](examples/usage/README.md): compiled, runnable usage examples that keep the README current.

<!-- agent-skills:begin -->
<!-- framework-commit: cab7c0590036edaa66d8430cc5016399a9fd2c71 origin: git@github.com:lostbean/skills.git -->

(Validation policy updated by the owner on 2026-10-20.)

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

**Shared validation** — `nix fmt` owns formatting; `nix flake check` checks it.
`nix run .#design-gate-check -- docs/design .` runs the imported design check.
CI invokes these checks directly. `nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf`
renders the layer; `nix run .#design-gate-context -- docs/design --estimate`
estimates context. Review documentation and conventions manually.

**Staleness** — source changes since the design last changed require a
conformance review before the layer is treated as current.

<!-- agent-skills:end -->

## README snippets

Keep README Gleam examples in compiled example or consumer source. Use named
`snips-start` / `snips-end` regions (or include a whole example module), and retain
Prettier ignore ranges around generated README blocks. Format the source first,
then run `nix run .#snips -- --commands deny README.md`. CI runs
`nix run .#snips -- --check --commands deny README.md` using the shared pinned
package. Snips checks synchronization; existing example tests check behavior.

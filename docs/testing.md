# Testing Sinal

## Package checks

- Run commands from the package root inside `nix develop`, or use `nix develop --command` for a single command. The supported runtime is Erlang/BEAM. The manifest pins the native oracle to telemetry 1.4.2; CI exercises Gleam 1.18.1 and OTP 28.
- `gleam build --warnings-as-errors` checks the production modules and native adapter build. `gleam test` runs field, registration, cleanup, span, correlation, forwarding, route, startup, module-documentation, README and stress checks.
- `nix fmt` formats the package. `nix flake check` checks the configured formatted-tree gate. `git diff --check` catches whitespace errors in the proposed diff.
- `nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf` rebuilds the single aggregate PDF. `nix run .#design-gate-check -- docs/design .` checks its artifact and link contracts. Read the rendered document as part of a design change; a successful syntax gate does not prove semantic fidelity.

## Validation profiles

```sh
nix develop --command python3 dev/gate.py fast
nix develop --command python3 dev/gate.py full
nix develop --command python3 dev/gate.py benchmark --artifacts .artifacts/benchmark
```

- `dev/gate.py` owns the profiles used by local checks and CI. `fast` checks full-tree formatting, authored tooling lint, Gleam formatting/build, independent native compilation, gate controls and the package test suite. `full` cleans the build and adds focused native behavior, stress, all synchronized forwarder races and the design gate.
- Native compilation uses `erlc -Werror` for authored production/test Erlang and the race probe asset, with downloaded dependency include paths and generated BEAM code paths. Gleam's `--warnings-as-errors` does not promote native Erlang warnings to failures. Gate controls compile a valid module and require an unused-variable module to fail with its intended diagnostic.
- The gate requires one nonempty successful Gleeunit summary. Controls reject empty, missing, failed, skipped and ambiguous summaries. Fault tests may emit native error reports; runtime logs are retained without a blanket warning filter.
- `nix flake check --print-build-logs` checks the original tree without formatting it. Nix pins actionlint, ShellCheck and Ruff through `flake.lock`; actionlint invokes ShellCheck for workflow shell commands, and ShellCheck also checks `.envrc`. Ruff checks authored `dev/*.py` for import, syntax and undefined/unused-name errors (E4/E7/E9/F), and treefmt applies Ruff formatting to that same scope.
- Formatting excludes generated build output, `.render`, PDF artifacts, transient `.artifacts` and frozen benchmark provenance JSON. Compiler rejection fixtures exist only in temporary directories; recorded benchmark output and oracle provenance remain evidence rather than generated replacements.
- `.artifacts/gate` retains each check's raw log and `summary.json`, including command, exit code, elapsed time and successful test count. A failed or timed-out command fails the profile and leaves the collected evidence. `--artifacts` selects another evidence directory.
- The `CI` workflow runs `full` on every push, pull request and manual dispatch. Its final `CI` job accepts only a successful validation job, so failure, cancellation and skipping cannot pass the complete status. Validation artifacts are retained for 14 days, including failed runs; missing expected evidence fails artifact collection.
- The separate benchmark workflow runs weekly and on manual dispatch. `benchmark` compiles Gleam and authored Erlang, then retains raw benchmark output, source SHA-256 hashes and command metadata for 30 days. It records observational results without latency thresholds; its scheduled result is separate from the required `CI` status.

| Obligation                                         | Authority                                         | Check / exact command                                                                         | Profile and owner                                | Enforcement                                 | Evidence                                                 |
| -------------------------------------------------- | ------------------------------------------------- | --------------------------------------------------------------------------------------------- | ------------------------------------------------ | ------------------------------------------- | -------------------------------------------------------- |
| Canonical formatting and tooling correctness       | Agent tooling rules; verification and maintenance | `nix flake check --print-build-logs`; `gleam format --check src test`                         | fast/full; Nix checks and package                | mechanism                                   | `nix-checks.log`, `gleam-format.log`                     |
| Warning-free authored build                        | Package compiler policy                           | `gleam build --warnings-as-errors`; gate's `erlc -Werror` command                             | fast/full/benchmark; package                     | mechanism                                   | `gleam-build.log`, `native-build.log`                    |
| Gate refusal and nonempty test execution           | Validation profiles above                         | `python3 dev/test_gate.py`; `gleam test`                                                      | fast/full; gate and package suite                | mechanism                                   | `gate-controls.log`, `package-tests.log`, passed count   |
| Native dispatch, concurrency and incarnation races | Verification and maintenance; ADR 0008            | `gleam run -m focused_behavior`; `gleam run -m stress_test`; `python3 dev/check_forwarder.py` | full; native harnesses                           | mechanism for the bounded scenarios         | Separate native and race logs                            |
| Design artifact integrity                          | Agent design gate contract                        | `nix run .#design-gate-check -- docs/design .`                                                | full; design gate                                | mechanism for artifact/reference checks     | `design.log`                                             |
| Workload-dependent performance observation         | Testing benchmarks; verification and maintenance  | `gleam run -m benchmark`                                                                      | scheduled/manual; benchmark program              | partial; no universal latency claim         | `.artifacts/benchmark/benchmark.log`, hashes and summary |
| Semantic design fidelity and separate consumer use | Verification and maintenance                      | Owning design review and Oversight consumers                                                  | Relevant boundary changes; package and consumers | convention here; separate consumer evidence | Owning review and consumer receipts                      |

## Focused native checks

```sh
nix develop --command gleam run -m focused_behavior
nix develop --command gleam run -m stress_test
nix develop --command python3 dev/check_forwarder.py
```

- The focused check verifies native attachment, decoded values and emitter-process identity. The stress harness exercises bounded attach/detach churn, concurrent emissions and span-context isolation.
- The forwarder checker copies production source into a temporary directory and adds synchronization barriers there. It leaves the package source unchanged. `--scenario startup`, `--scenario delayed_sender` and `--scenario delayed_drop` select publication, admission-restart and drop-notice races. `--source /path/to/checkout` selects a candidate tree; instrumentation assets remain beside the checker.
- The checker fails if its production anchors drift. Update its instrumentation and the corresponding race assertions together; do not interpret an anchor failure as proof of a runtime defect.
- Native callback placement, in-flight detach and restart guarantees use process barriers. A sleep can bound a test wait, but cannot establish that a competing process reached a particular causal step.

## Oracle and consumer evidence

- [Native oracle provenance](../test/oracle/telemetry-1.4.2.md) identifies the exact upstream source, license, cases and normalization. The mapped tests exercise Sinal's native boundary; they do not imply every upstream case is repeated under both registry modes.
- `test/readme_example_test.gleam` owns the executable README examples. Its snippet check requires every Gleam fence to occur verbatim in that module. Change the source example and README together when changing executable guidance.
- `test/sinal_module_docs_test.gleam` requires a module introduction for every public Gleam module. Keep internal modules under the package's declared internal module pattern.
- Separate consumer packages must use public imports to verify the ordinary path, advanced configuration, caller-owned records and typed failure handling. Package-internal FFI tests establish native behavior; consumer compilation establishes what an external caller can actually use.
- New custom codecs need exact-key encoding, round-trip and malformed foreign-value checks. Enumerations need a test that lists every constructor and round-trips each one; an exhaustive naming function alone does not prove that the value list is complete.

## Benchmarks

```sh
nix develop --command gleam run -m benchmark
```

- The executable reports runtime identity, warmup, iteration counts, total elapsed milliseconds, average time and throughput for zero-handler emission, typed synchronous handling, codec work and native spans. Route lookup reports averages with no routes and with one unrelated route. Each workload has one timed loop, not a distribution of per-operation samples. Preserve those parameters with any measurement you compare.
- [Recorded results](benchmarks/README.md) retain the workload, runtime, source hashes and raw output from the local run on 2026-10-06.
- The result is a local microbenchmark. It does not establish production latency, a bound on handler time, equality with raw telemetry, or capacity in bytes. Performance claims require a stated workload and a separate comparison.

## Documentation and release inspection

- `gleam docs build` checks generated module documentation. `gleam export hex-tarball` creates a local archive for inspection; it does not publish a package.
- Inspect the archive's production modules, native Erlang files, license, README and dependency manifest before an authorized release. Publishing and version decisions remain separate actions.

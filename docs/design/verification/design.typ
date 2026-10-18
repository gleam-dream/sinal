#import "../.render/designlib.typ": *

#let title = [Verification]
#let accent = "amber"

#let body = [
  #section(title: "Foundation", lead: "Native parity, public consumers and synchronized probes verify each contract at its real boundary.", body: [
    #goal(title: "Keep native behavior and typed boundaries executable")[Every contract in the observation and forwarding contexts is checked by a test, a native harness or a consumer. A claim without an executable check is marked as convention.]
    #goal(title: "Keep documentation examples executable")[Usage is documented as compiled, runnable examples (each a #term("term-usage-example")) in a separate package that depends on this one, and README snippets occur verbatim in them. Public module introductions are checked mechanically. A documented example cannot drift from compiling source, and no prose usage guide stands beside the examples.]
    #no-goal(title: "Measurements are not performance guarantees")[Benchmark and stress output is observational evidence from one workload and one machine. It establishes no latency bound, throughput promise or capacity limit.]
    #invariant(title: "A validation profile runs one nonempty successful test summary", enforcement: "mechanism")[The gate accepts exactly one successful Gleeunit summary with a nonzero test count. Empty, missing, failed, skipped and ambiguous summaries fail the profile.]
    #invariant(title: "Race evidence uses barriers, not elapsed time", enforcement: "mechanism")[A synchronization barrier establishes that a competing process reached a causal step. A sleep can bound a wait but never proves ordering.]
    #principle(title: "Evidence states its own limits")[Each check names what it proves and what it leaves open. A passing syntax gate does not prove semantic fidelity, and a passing oracle mapping does not prove every upstream case.]
  ])

  #section(title: "Validation profiles", lead: "One gate script owns the checks that local runs and CI share.", body: [
    #points(
      [The gate script offers three profiles: `fast`, `full` and `benchmark`. `fast` checks full-tree formatting, authored tooling lint, Gleam formatting and build, independent native compilation, gate controls, the package test suite and the usage examples.],
      [`full` cleans the build and adds the focused native behavior program, the stress harness, every synchronized forwarder race and the design gate. `benchmark` compiles Gleam and authored Erlang, runs the benchmark program and retains its raw output, source SHA-256 hashes and command metadata.],
      [Native compilation uses `erlc -Werror` for authored production and test Erlang and for the race-probe asset, with dependency include paths and generated BEAM code paths. Gleam's `--warnings-as-errors` does not promote native Erlang warnings, so this check is separate.],
      [Gate controls compile a valid module and require an unused-variable module to fail with its intended diagnostic. Further controls reject empty, missing, failed, skipped and ambiguous test summaries.],
      [`nix flake check` verifies the original tree without formatting it. The flake pins actionlint, ShellCheck and Ruff; actionlint invokes ShellCheck for workflow shell commands, and ShellCheck also checks `.envrc`.],
      [Ruff checks authored `dev/*.py` for import, syntax and undefined or unused names (E4/E7/E9/F), and treefmt applies Ruff formatting to the same scope. Formatting excludes build output, rendered documents, transient artifacts and frozen benchmark provenance.],
      [The gate retains each check's raw log and a `summary.json` with command, exit code, elapsed time and successful test count. A failed or timed-out command fails the profile and leaves the collected evidence in place.],
      [The CI workflow runs `full` on every push, pull request and manual dispatch. Its final status job accepts only a successful validation job, so failure, cancellation and skipping cannot pass. Validation artifacts are retained for 14 days, including failed runs, and missing expected evidence fails collection.],
      [A separate workflow runs `benchmark` weekly and on manual dispatch and retains its artifacts for 30 days. Its result is observational, carries no latency threshold and is independent of the required CI status.],
      [The Nix development shell pins Gleam, Erlang/OTP 29, rebar3 and Python. CI runs the same gate through that shell, so the supported toolchain is the flake lock rather than a separate CI matrix. #adr(10) records the profile split.],
    )
    #md-table(4, (
      [Obligation], [Check], [Profile], [Enforcement],
      [Canonical formatting and tooling correctness], [`nix flake check --print-build-logs`; `gleam format --check src test examples/usage/src examples/usage/test`], [fast, full], [mechanism],
      [Warning-free authored build], [`gleam build --warnings-as-errors`; the gate's `erlc -Werror` command], [fast, full, benchmark], [mechanism],
      [Gate refusal and nonempty test execution], [`python3 dev/test_gate.py`; `gleam test`], [fast, full], [mechanism],
      [Usage examples compile warning-free and run], [`gleam build --warnings-as-errors` and `gleam test` in `examples/usage`], [fast, full], [mechanism],
      [Native dispatch, concurrency and incarnation races], [`gleam run -m focused_behavior`; `gleam run -m stress_test`; `python3 dev/check_forwarder.py`], [full], [mechanism for the bounded scenarios],
      [Design artifact integrity], [`nix run .#design-gate-check -- docs/design .`], [full], [mechanism for artifact and reference checks],
      [Workload-dependent performance observation], [`gleam run -m benchmark`], [benchmark], [partial; no universal latency claim],
      [Semantic design fidelity and separate consumer use], [Design review and consumer packages], [on boundary changes], [convention],
    ))
  ])

  #section(title: "Native oracle", lead: "Telemetry 1.4.2 is the differential oracle for Sinal's native boundary.", body: [
    #subsection(title: "Pinned source and mapping scope")[
      #points(
        [The oracle is #term("term-native-oracle"): telemetry 1.4.2 at upstream revision `7baf8085e406d5ae9e43b284d7c866742ae04b28` under Apache 2.0, with Hex tarball checksum `928F6495066506077862C0D1646609EED891A4326BEE3126BA54B60AF61FEBB1`. The package manifest resolves 1.4.2 while the public dependency range admits later 1.x releases.],
        [Sinal replaces dynamic application terms with typed `Event` and `Fields` and preserves native atom-list names, measurement and metadata maps, references and exceptions. The wrapper converts none of those values through JSON.],
        [The mapping states semantic checks rather than a literal port of every upstream assertion. It does not claim to run every check in both upstream registry groups, and it adds Sinal-specific checks for typed decoding, scoped acquisition, correlation and forwarding.],
        [A fresh oracle harvest must record its own checkout, dependencies and result; a mapping change is not a harvest. #adr(9) records the pin.],
      )
    ]
    #subsection(title: "Case mapping and dispositions")[
      #points(
        [Every upstream case receives one disposition: adopted, adapted, no typed facade, adapter-specific, excluded or not claimed. The case-by-case table, its evidence and the normalization of each case live in #lnk("../../ORACLE.md")[the oracle reference], which also pins the sources and says how to rerun the comparison.],
        [Malformed application-map removal is adapted. Sinal reports a malformed measurement or metadata failure, skips that one invocation and keeps the registration, as #adr(4) records.],
        [Native introspection, the legacy two-argument entry point and the upstream test-helper API have no typed facade, because explicit codecs and Gleam assertions replace them. Raw callers and tests still use native introspection.],
        [Running every wrapper check under both the `ets` and `persisted` registry groups is not claimed, because it needs its own executable matrix. Sinal tests the raw `persist/0` transition separately.],
        [The local benchmark workloads and their retained run are in #lnk("../../BENCHMARKS.md")[the benchmark reference], which carries no behavioral claim.],
      )
    ]
  ])

  #section(title: "Focused checks and consumer obligations", lead: "Native harnesses and public consumers cover what unit tests cannot.", body: [
    #answers(title: "Verification contracts", accent: accent,
      responsibility: [Keep native behavior, typed boundaries, race guarantees and documentation examples executable.],
      interface: [Package tests, the focused behavior and stress programs, the peer-VM startup check, the forwarder race harness, the formatter and the design gate.],
      interactions: [Native telemetry is the differential oracle; consumer packages exercise public imports and real application types.],
      invariants: [Checks use the declared toolchain; barrier synchronization governs race evidence; README snippets match their executable source exactly.],
      failure: [A behavior mismatch, stale example, missing public module documentation, race-probe failure or stale design render fails its owning check.],
    )
    #subsection(title: "Native and race harnesses")[
      #points(
        [The focused program verifies native attachment, decoded values and emitter-process identity. The stress harness exercises bounded attach and detach churn, concurrent emissions and span-context isolation.],
        [The forwarder checker copies production source into a temporary directory and adds synchronization barriers there, leaving package source unchanged. Its scenarios select publication, admission-restart and drop-notice races, and an option selects a candidate source tree.],
        [The checker fails when its production anchors drift. An anchor failure requires updating the instrumentation and its race assertions together and is not evidence of a runtime defect.],
        [Native callback placement, in-flight detach and restart guarantees use process barriers. #adr(8) records why admission authority is incarnation-local.],
      )
    ]
    #subsection(title: "Consumers, examples and documentation")[
      #points(
        [A separate consumer package must use public imports to verify the ordinary path, advanced configuration, caller-owned records and typed failure handling. Package-internal tests establish native behavior, and consumer compilation establishes what an external caller can use.],
        [The usage examples are a package of their own under `examples/usage`, one module per topic, each with a `run` function that asserts what the example does. The validation profiles build them without warnings and run them after the package tests. The README test extracts every Gleam fence from the README and requires its exact text to occur in one of those modules, so a README example changes together with its executable source. #adr(14) records why usage lives in examples and why the oracle and benchmark references stay as linked documents.],
        [A module-documentation test requires an introduction for every public Gleam module, and internal modules stay under the declared internal-module pattern.],
        [A custom codec needs exact-key encoding, round-trip and malformed-foreign-value checks. An enumeration needs a test that lists every constructor and round-trips each one, because an exhaustive naming function does not prove that the value list is complete.],
        [Documentation generation and a local hex tarball inspection check the public modules, native Erlang files, license, README and dependency manifest before an authorized release. Publishing and version decisions are separate actions.],
      )
    ]
  ])

  #section(title: "Benchmark method", lead: "A benchmark run is a frozen, provenance-tagged observation.", body: [
    #points(
      [The benchmark program reports runtime identity, warmup and timed iteration counts, total elapsed time, average time and throughput for zero-handler emission, typed synchronous handling, codec work and native spans. Route lookup reports averages with no routes and with one unrelated route.],
      [Each workload is one timed loop whose average is total monotonic nanoseconds divided by iterations using integer division, including loop overhead. The result is a loop average, not a distribution of per-operation samples or a percentile.],
      [A recorded run keeps its workload parameters, runtime versions, source SHA-256 hashes and raw output together. A comparison with another run requires the same parameters and a stated workload.],
      [The result establishes no production latency, handler-time bound, equality with raw telemetry, forwarder throughput or capacity in bytes. #adr(11) records the accepted measurements and their limits.],
      [How to run the program, the environment and the retained run are in #lnk("../../BENCHMARKS.md")[the benchmark reference], and the pinned native reference is in #lnk("../../ORACLE.md")[the oracle reference]. Neither states a guarantee.],
    )
  ])
]

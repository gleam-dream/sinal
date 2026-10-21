#import "../.render/designlib.typ": *

#let title = [Verification]
#let accent = "amber"

#let body = [
  #section(title: "Foundation", lead: "Native parity, public consumers and synchronized probes verify each contract at its real boundary.", body: [
    #goal(title: "Keep native behavior and typed boundaries executable")[Every contract in the observation and forwarding contexts is checked by a test, a native harness or a consumer. A claim without an executable check is marked as convention.]
    #goal(title: "Keep documentation examples executable")[Usage is documented as compiled, runnable examples (each a #term("term-usage-example")) in a separate package that depends on this one, while README consistency and module introductions are reviewed manually.]
    #no-goal(title: "Measurements are not performance guarantees")[Benchmark and stress output is observational evidence from one workload and one machine. It establishes no latency bound, throughput promise or capacity limit.]
    #invariant(title: "Race evidence uses barriers, not elapsed time", enforcement: "mechanism")[A synchronization barrier establishes that a competing process reached a causal step. A sleep can bound a wait but never proves ordering.]
    #principle(title: "Evidence states its own limits")[Each check names what it proves and what it leaves open. A passing syntax gate does not prove semantic fidelity, and a passing oracle mapping does not prove every upstream case.]
  ])

  #pending-ledger(
    pending-entry(title: "Recheck carried-over verification claims against code", kind: "verify", since: "2026-10-17")[The validation profiles, the oracle case mapping with its exclusions and the benchmark method come from guides that no longer exist. Their statements about commands, case names and the retained run are not yet compared with the gate script, the oracle test cases and the recorded benchmark output.],
  )

  #section(title: "Validation profiles", lead: "Shared tools validate formatting and design; direct commands compile and test behavior.", body: [
    #points(
      [`sh dev/test fast` builds Gleam, compiles authored Erlang directly, runs the package tests and builds and runs the usage examples.],
      [`sh dev/test full` adds the focused native behavior program, the stress harness and every synchronized forwarder race. `gleam run -m benchmark` runs optional measurements directly.],
      [Native compilation uses `erlc -Werror` for authored production and test Erlang and for the race-probe asset. Gleam's `--warnings-as-errors` does not promote native Erlang warnings, so this check is separate.],
      [`nix flake check` checks formatting without repairing the working tree. CI also directly invokes the imported `nix run .#design-gate-check -- docs/design .`. Shared pinned Snips synchronizes README excerpts from compiled and tested usage examples. Bespoke README equality and repository-local documentation-policy checkers remain removed. #adr(15)],
      [The runner streams command output and stops on a failed command. It does not parse test summaries or require custom receipts.],
      [The CI workflow runs `full` on every push, pull request and manual dispatch. Its final status job accepts only a successful validation job, so failure, cancellation and skipping cannot pass.],
      [A separate workflow runs `gleam run -m benchmark` weekly and on manual dispatch and records its output in CI logs. Its result is observational, carries no latency threshold and is independent of the required CI status.],
      [The Nix development shell pins Gleam, Erlang/OTP 29, rebar3 and Python. CI runs the same gate through that shell, so the supported toolchain is the flake lock rather than a separate CI matrix. #adr(10) records the profile split.],
    )
    #md-table(4, (
      [Obligation], [Check], [Profile], [Enforcement],
      [Canonical formatting], [`nix flake check`], [CI and local validation], [mechanism],
      [Warning-free authored build], [`gleam build --warnings-as-errors`; the gate's `erlc -Werror` command], [fast, full], [mechanism],
      [Design integrity], [`nix run .#design-gate-check -- docs/design .`], [CI and design changes], [imported checker],
      [Package behavior], [`gleam test`], [fast, full], [mechanism],
      [Usage examples compile warning-free and run], [`gleam build --warnings-as-errors` and `gleam test` in `examples/usage`], [fast, full], [mechanism],
      [Native dispatch, concurrency and incarnation races], [`gleam run -m focused_behavior`; `gleam run -m stress_test`; `python3 dev/check_forwarder.py`], [full], [mechanism for the bounded scenarios],
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
      interface: [Package tests, the focused behavior and stress programs, the peer-VM startup check, the forwarder race harness, the formatter.],
      interactions: [Native telemetry is the differential oracle; consumer packages exercise public imports and real application types.],
      invariants: [Checks use the declared toolchain; barrier synchronization governs race evidence.],
      failure: [A behavior mismatch, compilation failure or race-probe failure fails its owning check.],
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
        [The usage examples are a package of their own under `examples/usage`, one module per topic, each with a `run` function that asserts what the example does. The validation profiles build them without warnings and run them after the package tests. README consistency is reviewed manually. #adr(14) records why usage lives in examples and why the oracle and benchmark references stay as linked documents.],
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

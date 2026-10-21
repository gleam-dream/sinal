#let terms = (
  (slug: "term-native-oracle", title: [Native oracle], body: [The pinned upstream telemetry release against which Sinal's native boundary is compared. It supplies expected behavior for mapped cases and no claim beyond them.]),
  (slug: "term-validation-profile", title: [Validation profile], body: [A named set of checks (`fast`, `full` or `benchmark`) that the gate script runs identically for local use and CI.]),
  (slug: "term-evidence-log", title: [Evidence log], body: [The raw output, command, exit code, elapsed time and test count that a check retains. A failed check leaves its log in place.]),
  (slug: "term-race-probe", title: [Race probe], body: [A check that runs a temporary copy of production source with synchronization barriers added. It establishes causal ordering of competing processes without changing package source.]),
  (slug: "term-benchmark-run", title: [Benchmark run], body: [One execution of the benchmark program with fixed workloads and iteration counts, retained with its runtime identity and source hashes. It is an observation, not a guarantee.]),
  (slug: "term-usage-example", title: [Usage example], body: [A compiled, runnable module under `examples/usage` that shows one public-API topic and asserts its result. The validation profiles build and run it.]),
)

# Retain benchmark averages as frozen, provenance-tagged runs

<a id="adr-0011"></a>

- Benchmark output is kept as observation with its workload, runtime, source hashes and raw receipt (`docs/benchmarks/2026-10-06.txt` and `docs/benchmarks/2026-10-06-provenance.json`). [docs/BENCHMARKS.md](../BENCHMARKS.md) holds the method, the run table and the limits, and links the [native oracle](../ORACLE.md) that the same workloads are compared against. It is not asserted by any test, because a threshold would couple correctness checks to one machine.
- The recorded run of 2026-10-06 used Gleam 1.18.1, Erlang/OTP 28 (ERTS 16.4.0.6), telemetry 1.4.2 and four BEAM schedulers on aarch64 Linux (four Cortex-A76 cores, reported maximum 2.4 GHz). CPU frequency and competing load were not recorded.
- Zero-handler emission averaged 392 ns per operation, one synchronous typed no-op handler including decode averaged 1,139 ns, a two-field codec round trip averaged 509 ns and a native span with no handlers averaged 1,211 ns. A three-segment emission averaged 290 ns with no routes and 387 ns with one unrelated route.
- Each figure is one timed loop of 20,000 to 50,000 iterations after warmup, so it includes loop overhead and is not a percentile. The run measured no forwarding queue and supports no comparison with a different harness.
- The source hashes describe the files measured before a later documentation cleanup that changed no executable code.
- Reporting only a headline number would hide the limits, and publishing a latency promise would claim more than one local loop supports.

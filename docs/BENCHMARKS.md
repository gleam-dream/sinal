# Benchmarks

Sinal keeps a small local microbenchmark program and one retained run of it. The numbers are observations from one machine and one workload. They establish no latency bound, throughput promise or capacity limit. [ORACLE.md](ORACLE.md) pins the native reference that the same workloads are compared against for behavior, and this document pins the measurements.

- **Design:** the [benchmark method](design/verification/design.typ#benchmark-method) section states the rules a run must follow, and [ADR 0011](adr/0011-retain-benchmark-averages-as-frozen-provenance-tagged-runs.md) records why runs are frozen with their provenance.
- **Commands:** [AGENTS.md](../AGENTS.md) lists the `benchmark` gate profile. A weekly workflow runs it and retains the artifacts, and its result is independent of the required CI status.

## Scope

The program [test/benchmark.gleam](../test/benchmark.gleam) times emission with no handlers, typed synchronous handling, codec work, native spans and route lookup. It measures no forwarding queue and no other harness.

## Method

The harness divides one loop's total monotonic elapsed nanoseconds by its iteration count, using integer division. Throughput uses the same elapsed time. The results are loop averages that include loop overhead, not latency percentiles or per-operation distributions. Total milliseconds in the receipt are truncated. The unrelated-route loop follows the no-route loop without a separate warmup.

A comparison with another run requires the same workload parameters and a stated workload. A recorded run keeps its parameters, runtime versions, source SHA-256 hashes and raw output together.

## How to run

From the package root:

```sh
nix develop --command gleam run -m benchmark
nix develop --command python3 dev/gate.py benchmark --artifacts .artifacts/benchmark
```

The first command prints a fresh run's runtime identity and measurements. The second also retains the raw output, source hashes and command metadata.

## Retained run

One run on 2026-10-06 used [test/benchmark.gleam](../test/benchmark.gleam). The [raw output](benchmarks/2026-10-06.txt) and [source hashes](benchmarks/2026-10-06-provenance.json) identify the measured inputs.

| Workload                                                                     | Warmup iterations | Timed iterations | Average ns/op | Operations/s |
| ---------------------------------------------------------------------------- | ----------------: | ---------------: | ------------: | -----------: |
| Emit an integer measurement and empty metadata, no handlers                  |            10,000 |           50,000 |           392 |    2,545,181 |
| Emit the same shape to one synchronous typed no-op handler, including decode |            10,000 |           50,000 |         1,139 |      877,917 |
| Encode and decode a two-field integer/boolean codec                          |            10,000 |           50,000 |           509 |    1,963,832 |
| Run a native span with start/stop metadata and no handlers                   |             5,000 |           20,000 |         1,211 |      825,178 |
| Emit a three-segment name with no handlers and no routes                     |            10,000 |           50,000 |           290 | Not reported |
| Emit the same name with one route on an unrelated prefix                     |   None separately |           50,000 |           387 | Not reported |

## Environment

The run used Gleam 1.18.1, Erlang/OTP 28, ERTS 16.4.0.6 and telemetry 1.4.2 on aarch64 Linux, with four BEAM schedulers. The available CPU identification is four ARM Cortex-A76 cores, with a reported maximum clock of 2.4 GHz. CPU frequency and competing load during the run were not recorded.

The checkout was at `44c5395938ce6da85378c475d8695f0ede492631` with uncommitted documentation and tooling changes. The source hashes describe the exact files before the prose and comment cleanup that followed, and the executable code was unchanged by it.

## Limits

These local results do not establish production latency, callback execution bounds, raw-telemetry parity or forwarder throughput. No forwarding queue is measured, and no comparison with a different harness or with older measurements is implied. No test asserts a latency threshold.

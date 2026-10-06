# Local microbenchmark results

One run on 2026-10-06 used [test/benchmark.gleam](../../test/benchmark.gleam) in the current checkout. [Raw output](2026-10-06.txt) and [source hashes](2026-10-06-provenance.json) identify the measured inputs.

| Workload                                                                     | Warmup iterations | Timed iterations | Average ns/op | Operations/s |
| ---------------------------------------------------------------------------- | ----------------: | ---------------: | ------------: | -----------: |
| Emit an integer measurement and empty metadata, no handlers                  |            10,000 |           50,000 |           392 |    2,545,181 |
| Emit the same shape to one synchronous typed no-op handler, including decode |            10,000 |           50,000 |         1,139 |      877,917 |
| Encode and decode a two-field integer/boolean codec                          |            10,000 |           50,000 |           509 |    1,963,832 |
| Run a native span with start/stop metadata and no handlers                   |             5,000 |           20,000 |         1,211 |      825,178 |
| Emit a three-segment name with no handlers and no routes                     |            10,000 |           50,000 |           290 | Not reported |
| Emit the same name with one route on an unrelated prefix                     |   None separately |           50,000 |           387 | Not reported |

The harness divides one loop's total monotonic elapsed nanoseconds by its iteration count, using integer division. Throughput uses the same elapsed time. These are loop averages, including loop overhead, rather than latency percentiles. Total milliseconds in the receipt are truncated. The unrelated-route loop follows the no-route loop without a separate warmup.

The run used Gleam 1.18.1, Erlang/OTP 28, ERTS 16.4.0.6 and telemetry 1.4.2 on aarch64 Linux, with four BEAM schedulers. The available CPU identification is four ARM Cortex-A76 cores, with a reported maximum clock of 2.4 GHz. CPU frequency and competing load during the run were not recorded.

The checkout was at `44c5395938ce6da85378c475d8695f0ede492631` with uncommitted documentation and tooling changes. The source hashes describe the exact files before this prose and comment cleanup; executable code is unchanged by the cleanup.

Reproduce from the package root:

```sh
nix develop --command gleam run -m benchmark
```

A fresh run prints its own runtime identity and measurements. These local results do not establish production latency, callback execution bounds, raw-telemetry parity or forwarder throughput. No forwarding queue is measured here, and no comparison with a different harness or older measurements is implied.

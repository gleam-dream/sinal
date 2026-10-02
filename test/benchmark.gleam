import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/io
import sinal
import sinal/fields
import sinal/forwarder
import sinal/span

@external(erlang, "scope_test_ffi", "get_otp_release")
fn get_otp_release() -> String

@external(erlang, "scope_test_ffi", "monotonic_nanos")
fn monotonic_nanos() -> Int

fn loop_n(n: Int, action: fn(Int) -> Nil) -> Nil {
  case n <= 0 {
    True -> Nil
    False -> {
      action(n)
      loop_n(n - 1, action)
    }
  }
}

pub fn main() {
  let otp = get_otp_release()
  io.println(
    "================================================================================",
  )
  io.println("Sinal Baseline Microbenchmarks")
  io.println("Erlang/OTP Release: " <> otp)
  io.println("Target: BEAM Native (direct :telemetry binding)")
  io.println(
    "================================================================================",
  )

  bench_zero_handler()
  bench_single_handler()
  bench_codec()
  bench_span()
  bench_unrouted()

  io.println(
    "================================================================================",
  )
  io.println("Baseline benchmarks complete.")
}

fn bench_zero_handler() {
  let val_field = fields.field("value", dynamic.int, decode.int)
  let ev = sinal.event(["bench", "zero_handler"], val_field, fields.empty())

  let warmup = 10_000
  let samples = 50_000

  // Warmup
  loop_n(warmup, fn(i) { sinal.emit(ev, i, Nil) })

  // Sample
  let start_t = monotonic_nanos()
  loop_n(samples, fn(i) { sinal.emit(ev, i, Nil) })
  let end_t = monotonic_nanos()

  let total_nanos = end_t - start_t
  let ns_per_op = total_nanos / samples
  let ops_per_sec = case total_nanos > 0 {
    True -> { samples * 1_000_000_000 } / total_nanos
    False -> 0
  }

  io.println("1. Zero-handler emission (sinal.emit with no attached handlers):")
  io.println(
    "   Samples:    "
    <> int.to_string(samples)
    <> " iterations (warmup: "
    <> int.to_string(warmup)
    <> ")",
  )
  io.println(
    "   Total time: " <> int.to_string(total_nanos / 1_000_000) <> " ms",
  )
  io.println("   Latency:    " <> int.to_string(ns_per_op) <> " ns/op")
  io.println("   Throughput: " <> int.to_string(ops_per_sec) <> " ops/sec\n")
}

fn bench_single_handler() {
  let val_field = fields.field("value", dynamic.int, decode.int)
  let ev = sinal.event(["bench", "single_handler"], val_field, fields.empty())
  let att = sinal.observe(ev, fn(_val: Int, _meta) { Nil })

  let warmup = 10_000
  let samples = 50_000

  // Warmup
  loop_n(warmup, fn(i) { sinal.emit(ev, i, Nil) })

  // Sample
  let start_t = monotonic_nanos()
  loop_n(samples, fn(i) { sinal.emit(ev, i, Nil) })
  let end_t = monotonic_nanos()

  let total_nanos = end_t - start_t
  let ns_per_op = total_nanos / samples
  let ops_per_sec = case total_nanos > 0 {
    True -> { samples * 1_000_000_000 } / total_nanos
    False -> 0
  }

  let _ = sinal.detach(att)

  io.println(
    "2. Synchronous emission with 1 typed handler (sinal.emit + decode):",
  )
  io.println(
    "   Samples:    "
    <> int.to_string(samples)
    <> " iterations (warmup: "
    <> int.to_string(warmup)
    <> ")",
  )
  io.println(
    "   Total time: " <> int.to_string(total_nanos / 1_000_000) <> " ms",
  )
  io.println("   Latency:    " <> int.to_string(ns_per_op) <> " ns/op")
  io.println("   Throughput: " <> int.to_string(ops_per_sec) <> " ops/sec\n")
}

fn bench_codec() {
  let pair_codec =
    fields.record({
      use user_id <- fields.parameter
      use active <- fields.parameter
      #(user_id, active)
    })
    |> fields.and(fields.int("user_id"), fn(p: #(Int, Bool)) { p.0 })
    |> fields.and(fields.bool("active"), fn(p) { p.1 })
    |> fields.build

  let warmup = 10_000
  let samples = 50_000

  // Warmup
  loop_n(warmup, fn(i) {
    let encoded = fields.encode(pair_codec, #(i, True))
    let assert Ok(_) = fields.decode(pair_codec, encoded)
    Nil
  })

  // Sample
  let start_t = monotonic_nanos()
  loop_n(samples, fn(i) {
    let encoded = fields.encode(pair_codec, #(i, True))
    let assert Ok(_) = fields.decode(pair_codec, encoded)
    Nil
  })
  let end_t = monotonic_nanos()

  let total_nanos = end_t - start_t
  let ns_per_op = total_nanos / samples
  let ops_per_sec = case total_nanos > 0 {
    True -> { samples * 1_000_000_000 } / total_nanos
    False -> 0
  }

  io.println(
    "3. Pure typed field encoding + decoding (fields.encode + decode):",
  )
  io.println(
    "   Samples:    "
    <> int.to_string(samples)
    <> " iterations (warmup: "
    <> int.to_string(warmup)
    <> ")",
  )
  io.println(
    "   Total time: " <> int.to_string(total_nanos / 1_000_000) <> " ms",
  )
  io.println("   Latency:    " <> int.to_string(ns_per_op) <> " ns/op")
  io.println("   Throughput: " <> int.to_string(ops_per_sec) <> " ops/sec\n")
}

pub type BenchSpanMeta {
  BenchSpanMeta(op: String)
}

fn bench_span() {
  let op_field =
    fields.field(
      "op",
      fn(m: BenchSpanMeta) { dynamic.string(m.op) },
      decode.string |> decode.map(BenchSpanMeta),
    )
  let sp =
    span.define(
      ["bench", "span"],
      start_metadata: op_field,
      stop_measurements: fields.empty(),
      stop_metadata: op_field,
    )

  let warmup = 5000
  let samples = 20_000

  // Warmup
  loop_n(warmup, fn(_) {
    let _ =
      span.run(sp, BenchSpanMeta("query"), fn() {
        span.Completion(Ok(1), Nil, BenchSpanMeta("query_done"))
      })
    Nil
  })

  // Sample
  let start_t = monotonic_nanos()
  loop_n(samples, fn(_) {
    let _ =
      span.run(sp, BenchSpanMeta("query"), fn() {
        span.Completion(Ok(1), Nil, BenchSpanMeta("query_done"))
      })
    Nil
  })
  let end_t = monotonic_nanos()

  let total_nanos = end_t - start_t
  let ns_per_op = total_nanos / samples
  let ops_per_sec = case total_nanos > 0 {
    True -> { samples * 1_000_000_000 } / total_nanos
    False -> 0
  }

  io.println("4. Native span execution (span.run with start + stop events):")
  io.println(
    "   Samples:    "
    <> int.to_string(samples)
    <> " iterations (warmup: "
    <> int.to_string(warmup)
    <> ")",
  )
  io.println(
    "   Total time: " <> int.to_string(total_nanos / 1_000_000) <> " ms",
  )
  io.println("   Latency:    " <> int.to_string(ns_per_op) <> " ns/op")
  io.println("   Throughput: " <> int.to_string(ops_per_sec) <> " ops/sec\n")
}

fn bench_unrouted() {
  let ev =
    sinal.event(
      ["bench", "unrouted", "event"],
      fields.int("value"),
      fields.empty(),
    )

  let warmup = 10_000
  let samples = 50_000

  loop_n(warmup, fn(i) { sinal.emit(ev, i, Nil) })

  let start_t = monotonic_nanos()
  loop_n(samples, fn(i) { sinal.emit(ev, i, Nil) })
  let no_routes_nanos = monotonic_nanos() - start_t

  // A route on another prefix makes every emit scan the route list.
  let other = forwarder.new(process.new_name("bench_other_forwarder"))
  forwarder.route(["bench_other"], other)
  let routed_start = monotonic_nanos()
  loop_n(samples, fn(i) { sinal.emit(ev, i, Nil) })
  let other_route_nanos = monotonic_nanos() - routed_start
  forwarder.unroute(["bench_other"])

  io.println(
    "5. Route lookup (sinal.emit, three-segment name, no handlers, not routed):",
  )
  io.println(
    "   Samples:    "
    <> int.to_string(samples)
    <> " iterations (warmup: "
    <> int.to_string(warmup)
    <> ")",
  )
  io.println(
    "   Latency:    "
    <> int.to_string(no_routes_nanos / samples)
    <> " ns/op with no routes, "
    <> int.to_string(other_route_nanos / samples)
    <> " ns/op with one route on another prefix\n",
  )
}

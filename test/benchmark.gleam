import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
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
  let ev_name = [atom.create("bench"), atom.create("zero_handler")]
  let key = atom.create("value")
  let val_field =
    fields.field(key, fn(i: Int) { Ok(dynamic.int(i)) }, fn(dyn) {
      case decode.run(dyn, decode.int) {
        Ok(i) -> Ok(i)
        Error(_) -> Error(fields.FieldDecodeError("expected int"))
      }
    })
  let assert Ok(ev) = sinal.event(ev_name, val_field, fields.empty())

  let warmup = 10_000
  let samples = 50_000

  // Warmup
  loop_n(warmup, fn(i) {
    let assert Ok(Nil) = sinal.emit(ev, i, Nil)
    Nil
  })

  // Sample
  let start_t = monotonic_nanos()
  loop_n(samples, fn(i) {
    let assert Ok(Nil) = sinal.emit(ev, i, Nil)
    Nil
  })
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
  let ev_name = [atom.create("bench"), atom.create("single_handler")]
  let key = atom.create("value")
  let val_field =
    fields.field(key, fn(i: Int) { Ok(dynamic.int(i)) }, fn(dyn) {
      case decode.run(dyn, decode.int) {
        Ok(i) -> Ok(i)
        Error(_) -> Error(fields.FieldDecodeError("expected int"))
      }
    })
  let assert Ok(ev) = sinal.event(ev_name, val_field, fields.empty())
  let assert Ok(hid) = sinal.handler_id("bench-single-handler")

  let handler = fn(_ev, _val: Int, _meta) { Ok(Nil) }
  let assert Ok(att) = sinal.attach(hid, ev, handler, fn(_, _) { Nil })

  let warmup = 10_000
  let samples = 50_000

  // Warmup
  loop_n(warmup, fn(i) {
    let assert Ok(Nil) = sinal.emit(ev, i, Nil)
    Nil
  })

  // Sample
  let start_t = monotonic_nanos()
  loop_n(samples, fn(i) {
    let assert Ok(Nil) = sinal.emit(ev, i, Nil)
    Nil
  })
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
  let key_a = atom.create("user_id")
  let key_b = atom.create("active")
  let field_a =
    fields.field(key_a, fn(i: Int) { Ok(dynamic.int(i)) }, fn(dyn) {
      case decode.run(dyn, decode.int) {
        Ok(i) -> Ok(i)
        Error(_) -> Error(fields.FieldDecodeError("expected int"))
      }
    })
  let field_b =
    fields.field(key_b, fn(b: Bool) { Ok(dynamic.bool(b)) }, fn(dyn) {
      case decode.run(dyn, decode.bool) {
        Ok(b) -> Ok(b)
        Error(_) -> Error(fields.FieldDecodeError("expected bool"))
      }
    })
  let assert Ok(pair_codec) = fields.pair(field_a, field_b)

  let warmup = 10_000
  let samples = 50_000

  // Warmup
  loop_n(warmup, fn(i) {
    let assert Ok(encoded) = fields.encode(pair_codec, #(i, True))
    let assert Ok(_) = fields.decode(pair_codec, encoded)
    Nil
  })

  // Sample
  let start_t = monotonic_nanos()
  loop_n(samples, fn(i) {
    let assert Ok(encoded) = fields.encode(pair_codec, #(i, True))
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
  let prefix = [atom.create("bench"), atom.create("span")]
  let assert Ok(p) = span.event_prefix(prefix)
  let op_key = atom.create("op")
  let op_field =
    fields.field(
      op_key,
      fn(m: BenchSpanMeta) { Ok(dynamic.string(m.op)) },
      fn(dyn) {
        case decode.run(dyn, decode.string) {
          Ok(s) -> Ok(BenchSpanMeta(s))
          Error(_) -> Error(fields.FieldDecodeError("expected string"))
        }
      },
    )
  let assert Ok(sp) = span.define_span(p, op_field, fields.empty(), op_field)

  let warmup = 5000
  let samples = 20_000

  // Warmup
  loop_n(warmup, fn(_) {
    let _ =
      span.run_span(sp, BenchSpanMeta("query"), fn() {
        span.Completion(Ok(1), Nil, BenchSpanMeta("query_done"))
      })
    Nil
  })

  // Sample
  let start_t = monotonic_nanos()
  loop_n(samples, fn(_) {
    let _ =
      span.run_span(sp, BenchSpanMeta("query"), fn() {
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

  io.println(
    "4. Native span execution (span.run_span with start + stop events):",
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

fn bench_unrouted() {
  let ev_name = [
    atom.create("bench"),
    atom.create("unrouted"),
    atom.create("event"),
  ]
  let assert Ok(ev) =
    sinal.event(ev_name, fields.int(atom.create("value")), fields.empty())

  let warmup = 10_000
  let samples = 50_000

  loop_n(warmup, fn(i) {
    let assert Ok(Nil) = forwarder.emit_routed(ev, i, Nil)
    Nil
  })

  let start_t = monotonic_nanos()
  loop_n(samples, fn(i) {
    let assert Ok(Nil) = forwarder.emit_routed(ev, i, Nil)
    Nil
  })
  let total_nanos = monotonic_nanos() - start_t

  let direct_start = monotonic_nanos()
  loop_n(samples, fn(i) {
    let assert Ok(Nil) = sinal.emit(ev, i, Nil)
    Nil
  })
  let direct_nanos = monotonic_nanos() - direct_start

  io.println(
    "5. Unrouted emission (forwarder.emit_routed, three-atom name, no route, no handlers):",
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
    <> int.to_string(total_nanos / samples)
    <> " ns/op (sinal.emit on the same event: "
    <> int.to_string(direct_nanos / samples)
    <> " ns/op)\n",
  )
}

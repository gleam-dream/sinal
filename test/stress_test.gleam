import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/list
import gleeunit/should
import sinal
import sinal/fields
import sinal/span

pub fn main() {
  repeated_attach_emit_detach_stress_test()
  concurrent_emitters_high_throughput_stress_test()
  concurrent_spans_stress_test()
}

fn range(start: Int, stop: Int) -> List(Int) {
  case start > stop {
    True -> []
    False -> [start, ..range(start + 1, stop)]
  }
}

pub fn repeated_attach_emit_detach_stress_test() {
  let ev_name = [atom.create("stress"), atom.create("lifecycle_churn")]
  let key = atom.create("iteration")
  let iter_field =
    fields.field(key, fn(i: Int) { Ok(dynamic.int(i)) }, fn(dyn) {
      case decode.run(dyn, decode.int) {
        Ok(i) -> Ok(i)
        Error(_) -> Error(fields.FieldDecodeError("expected int"))
      }
    })
  let assert Ok(ev) = sinal.event(ev_name, iter_field, fields.empty())
  let subject = process.new_subject()

  // 50 rapid sequential attach -> emit -> detach cycles with unique IDs
  list.each(range(1, 50), fn(i) {
    let id_str = "stress-churn-handler-" <> int.to_string(i)
    let assert Ok(hid) = sinal.handler_id(id_str)
    let handler = fn(_ev, iter: Int, _meta) {
      process.send(subject, iter)
      Ok(Nil)
    }
    let assert Ok(att) = sinal.attach(hid, ev, handler, fn(_, _) { Nil })

    // Emit and verify exact delivery
    let assert Ok(Nil) = sinal.emit(ev, i, Nil)
    let assert Ok(received) = process.receive(subject, 100)
    received |> should.equal(i)

    // Detach and verify post-detach emission does not invoke handler
    let assert Ok(Nil) = sinal.detach(att)
    let assert Ok(Nil) = sinal.emit(ev, i, Nil)
    process.receive(subject, 20) |> should.be_error()

    // Repeated detach returns NotAttached
    sinal.detach(att) |> should.equal(Error(sinal.NotAttached))
  })
}

pub fn concurrent_emitters_high_throughput_stress_test() {
  let ev_name = [atom.create("stress"), atom.create("concurrent_flood")]
  let worker_key = atom.create("worker_id")
  let seq_key = atom.create("seq")

  let worker_field =
    fields.field(worker_key, fn(w: Int) { Ok(dynamic.int(w)) }, fn(dyn) {
      case decode.run(dyn, decode.int) {
        Ok(w) -> Ok(w)
        Error(_) -> Error(fields.FieldDecodeError("expected int"))
      }
    })
  let seq_field =
    fields.field(seq_key, fn(s: Int) { Ok(dynamic.int(s)) }, fn(dyn) {
      case decode.run(dyn, decode.int) {
        Ok(s) -> Ok(s)
        Error(_) -> Error(fields.FieldDecodeError("expected int"))
      }
    })
  let assert Ok(meas_fields) = fields.pair(worker_field, seq_field)
  let assert Ok(ev) = sinal.event(ev_name, meas_fields, fields.empty())

  let assert Ok(hid) = sinal.handler_id("stress-flood-handler")
  let collector_subject = process.new_subject()

  let handler = fn(_ev, meas: #(Int, Int), _meta) {
    process.send(collector_subject, meas)
    Ok(Nil)
  }
  let assert Ok(att) = sinal.attach(hid, ev, handler, fn(_, _) { Nil })

  let num_workers = 10
  let events_per_worker = 50
  let total_events = num_workers * events_per_worker

  // Spawn num_workers concurrent emitter processes
  list.each(range(1, num_workers), fn(w) {
    process.spawn(fn() {
      list.each(range(1, events_per_worker), fn(s) {
        let assert Ok(Nil) = sinal.emit(ev, #(w, s), Nil)
        Nil
      })
    })
  })

  // Collect all total_events deterministically
  let received_events =
    list.map(range(1, total_events), fn(_) {
      let assert Ok(event) = process.receive(collector_subject, 2000)
      event
    })

  // Verify total count
  list.length(received_events) |> should.equal(total_events)

  // Verify every worker emitted all their sequential items
  list.each(range(1, num_workers), fn(w) {
    list.each(range(1, events_per_worker), fn(s) {
      list.contains(received_events, #(w, s))
      |> should.equal(True)
    })
  })

  // Clean detachment
  sinal.detach(att) |> should.equal(Ok(Nil))
}

pub type StressSpanMeta {
  StressSpanMeta(worker: Int)
}

pub fn concurrent_spans_stress_test() {
  let prefix = [atom.create("stress_span"), atom.create("worker")]
  let assert Ok(p) = span.event_prefix(prefix)

  let worker_key = atom.create("worker")
  let worker_field =
    fields.field(
      worker_key,
      fn(m: StressSpanMeta) { Ok(dynamic.int(m.worker)) },
      fn(dyn) {
        case decode.run(dyn, decode.int) {
          Ok(w) -> Ok(StressSpanMeta(w))
          Error(_) -> Error(fields.FieldDecodeError("expected int"))
        }
      },
    )

  let assert Ok(sp) =
    span.define_span(p, worker_field, fields.empty(), worker_field)
  let events = span.events(sp)

  let start_subject = process.new_subject()
  let stop_subject = process.new_subject()

  let start_handler = fn(
    _ev,
    _meas: span.StartMeasurements,
    meta: span.StartMetadata(StressSpanMeta),
  ) {
    process.send(start_subject, #(meta.metadata.worker, meta.context))
    Ok(Nil)
  }
  let stop_handler = fn(
    _ev,
    _meas: span.StopMeasurements(Nil),
    meta: span.StopMetadata(StressSpanMeta),
  ) {
    process.send(stop_subject, #(meta.metadata.worker, meta.context))
    Ok(Nil)
  }

  let assert Ok(hid_start) = sinal.handler_id("stress-span-start")
  let assert Ok(hid_stop) = sinal.handler_id("stress-span-stop")
  let assert Ok(att_start) =
    sinal.attach(hid_start, events.start, start_handler, fn(_, _) { Nil })
  let assert Ok(att_stop) =
    sinal.attach(hid_stop, events.stop, stop_handler, fn(_, _) { Nil })

  let num_spans = 20

  // Run num_spans concurrent spans
  list.each(range(1, num_spans), fn(i) {
    process.spawn(fn() {
      let result =
        span.run_span(sp, StressSpanMeta(worker: i), fn() {
          span.Completion(
            result: i * 10,
            measurements: Nil,
            metadata: StressSpanMeta(worker: i),
          )
        })
      result |> should.equal(i * 10)
      Nil
    })
  })

  // Collect all start and stop events
  let starts =
    list.map(range(1, num_spans), fn(_) {
      let assert Ok(item) = process.receive(start_subject, 2000)
      item
    })
  let stops =
    list.map(range(1, num_spans), fn(_) {
      let assert Ok(item) = process.receive(stop_subject, 2000)
      item
    })

  list.length(starts) |> should.equal(num_spans)
  list.length(stops) |> should.equal(num_spans)

  // Verify that for every span worker, start.context == stop.context
  // and each context is a valid BEAM native reference
  list.each(range(1, num_spans), fn(i) {
    let assert Ok(#(_, start_ctx)) =
      list.find(starts, fn(item: #(Int, span.SpanContext)) { item.0 == i })
    let assert Ok(#(_, stop_ctx)) =
      list.find(stops, fn(item: #(Int, span.SpanContext)) { item.0 == i })
    start_ctx |> should.equal(stop_ctx)
    is_native_reference(span.span_context_to_dynamic(start_ctx))
    |> should.equal(True)
  })

  // Collect all contexts and assert all worker contexts are mutually distinct
  let start_contexts = list.map(starts, fn(item) { item.1 })
  let stop_contexts = list.map(stops, fn(item) { item.1 })

  list.length(list.unique(start_contexts)) |> should.equal(num_spans)
  list.length(list.unique(stop_contexts)) |> should.equal(num_spans)

  // Pairwise mutual distinctness verification across distinct workers
  list.each(range(1, num_spans), fn(i) {
    let assert Ok(#(_, ctx_i)) =
      list.find(starts, fn(item: #(Int, span.SpanContext)) { item.0 == i })
    list.each(range(i + 1, num_spans), fn(j) {
      let assert Ok(#(_, ctx_j)) =
        list.find(starts, fn(item: #(Int, span.SpanContext)) { item.0 == j })
      ctx_i |> should.not_equal(ctx_j)
    })
  })

  sinal.detach(att_start) |> should.equal(Ok(Nil))
  sinal.detach(att_stop) |> should.equal(Ok(Nil))
}

@external(erlang, "scope_test_ffi", "is_native_reference")
fn is_native_reference(term: dynamic.Dynamic) -> Bool

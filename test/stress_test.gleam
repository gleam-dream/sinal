import gleam/dynamic
import gleam/dynamic/decode
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
  let iter_field = fields.field("iteration", dynamic.int, decode.int)
  let ev =
    sinal.event(["stress", "lifecycle_churn"], iter_field, fields.empty())
  let subject = process.new_subject()

  // 50 rapid sequential attach -> emit -> detach cycles with unique IDs
  list.each(range(1, 50), fn(i) {
    let handler = fn(_ev, iter: Int, _meta) {
      process.send(subject, iter)
      Ok(Nil)
    }
    let assert Ok(att) =
      sinal.attach(
        sinal.handler([ev], handler, fn(_, _) { Nil })
        |> sinal.with_id("stress-churn-handler-" <> int.to_string(i)),
      )

    // Emit and verify exact delivery
    sinal.emit(ev, i, Nil)
    let assert Ok(received) = process.receive(subject, 100)
    received |> should.equal(i)

    // Detach and verify post-detach emission does not invoke handler
    let assert Ok(Nil) = sinal.detach(att)
    sinal.emit(ev, i, Nil)
    process.receive(subject, 20) |> should.be_error()

    // Repeated detach reports the handler as not attached
    sinal.detach(att) |> should.equal(Error(Nil))
  })
}

pub fn concurrent_emitters_high_throughput_stress_test() {
  let meas_fields =
    fields.record({
      use worker_id <- fields.parameter
      use seq <- fields.parameter
      #(worker_id, seq)
    })
    |> fields.and(fields.int("worker_id"), fn(m: #(Int, Int)) { m.0 })
    |> fields.and(fields.int("seq"), fn(m) { m.1 })
    |> fields.build
  let ev =
    sinal.event(["stress", "concurrent_flood"], meas_fields, fields.empty())

  let collector_subject = process.new_subject()
  let att =
    sinal.observe(ev, fn(meas: #(Int, Int), _meta) {
      process.send(collector_subject, meas)
    })

  let num_workers = 10
  let events_per_worker = 50
  let total_events = num_workers * events_per_worker

  // Spawn num_workers concurrent emitter processes
  list.each(range(1, num_workers), fn(w) {
    process.spawn(fn() {
      list.each(range(1, events_per_worker), fn(s) {
        sinal.emit(ev, #(w, s), Nil)
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
  let worker_field =
    fields.field(
      "worker",
      fn(m: StressSpanMeta) { dynamic.int(m.worker) },
      decode.int |> decode.map(StressSpanMeta),
    )

  let sp =
    span.define(
      ["stress_span", "worker"],
      start_metadata: worker_field,
      stop_measurements: fields.empty(),
      stop_metadata: worker_field,
    )
  let events = span.events(sp)

  let start_subject = process.new_subject()
  let stop_subject = process.new_subject()

  let att_start =
    sinal.observe(
      events.start,
      fn(
        _meas: span.StartMeasurements,
        meta: span.StartMetadata(StressSpanMeta),
      ) {
        process.send(start_subject, #(meta.metadata.worker, meta.context))
      },
    )
  let att_stop =
    sinal.observe(
      events.stop,
      fn(
        _meas: span.StopMeasurements(Nil),
        meta: span.StopMetadata(StressSpanMeta),
      ) {
        process.send(stop_subject, #(meta.metadata.worker, meta.context))
      },
    )

  let num_spans = 20

  // Run num_spans concurrent spans
  list.each(range(1, num_spans), fn(i) {
    process.spawn(fn() {
      let result =
        span.run(sp, StressSpanMeta(worker: i), fn() {
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
    is_native_reference(span_context_term(start_ctx))
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

@external(erlang, "scope_test_ffi", "span_context_term")
fn span_context_term(context: span.SpanContext) -> dynamic.Dynamic

@external(erlang, "scope_test_ffi", "is_native_reference")
fn is_native_reference(term: dynamic.Dynamic) -> Bool

//// A decode failure in a handler skips that one invocation: the handler
//// stays attached, the emitter does not crash, and the failure reaches the
//// handler's typed failure observer (or the log, for `observe`).

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import sinal
import sinal/fields
import sinal/internal/ffi
import sinal/span

pub type Outcome {
  Delivered
  Retried
}

fn outcome_name(outcome: Outcome) -> String {
  case outcome {
    Delivered -> "delivered"
    Retried -> "retried"
  }
}

/// The list forgets `Retried`, as the webhooks app's did: the compiler
/// cannot see it.
fn incomplete_outcome() -> fields.Fields(Outcome) {
  fields.enum("outcome", [Delivered], outcome_name)
}

pub fn observe_keeps_handler_after_unlisted_enum_value_test() {
  let ev =
    sinal.event(
      ["decode_failure", "observe"],
      fields.empty(),
      incomplete_outcome(),
    )
  let seen = process.new_subject()
  let #(attachment, logs) =
    capture_warnings(fn() {
      let attachment =
        sinal.observe(ev, fn(_, outcome) { process.send(seen, outcome) })
      // The unlisted value neither crashes the emitter nor detaches.
      sinal.emit(ev, Nil, Retried)
      sinal.emit(ev, Nil, Delivered)
      attachment
    })
  process.receive(seen, 100) |> should.equal(Ok(Delivered))
  process.receive(seen, 20) |> should.be_error()
  sinal.detach(attachment) |> should.equal(Ok(Nil))
  // One report from the emit site, one from the skipped invocation.
  list.any(logs, string.contains(
    _,
    "sinal.emit: event [\"decode_failure\", \"observe\"]",
  ))
  |> should.equal(True)
  list.any(logs, string.contains(
    _,
    "sinal.observe: skipped one invocation of event [\"decode_failure\", \"observe\"]: malformed metadata: invalid value at key outcome",
  ))
  |> should.equal(True)
}

pub fn handler_reports_decode_failures_and_stays_attached_test() {
  let ev =
    sinal.event(
      ["decode_failure", "handler"],
      fields.int("count"),
      incomplete_outcome(),
    )
  let failures = process.new_subject()
  let runs = process.new_subject()
  let native_failures = process.new_subject()
  let listener_id = ffi.to_dynamic(atom.create("decode_failure_listener"))
  let assert Ok(Nil) =
    ffi.telemetry_attach_many(
      listener_id,
      [
        [
          atom.create("telemetry"),
          atom.create("handler"),
          atom.create("failure"),
        ],
      ],
      fn(_, _, _) { process.send(native_failures, Nil) },
    )
  let assert Ok(attachment) =
    sinal.attach(
      sinal.handler(
        [ev],
        fn(_, count, outcome) {
          process.send(runs, #(count, outcome))
          Ok(Nil)
        },
        fn(_, failure) { process.send(failures, failure) },
      ),
    )

  let _ = capture_warnings(fn() { sinal.emit(ev, 1, Retried) })
  let assert Ok(sinal.MalformedMetadata(fields.InvalidField("outcome", _))) =
    process.receive(failures, 100)
  native_emit(
    ["decode_failure", "handler"],
    native_map([#("count", dynamic.string("x"))]),
    native_map([#("outcome", dynamic.string("delivered"))]),
  )
  let assert Ok(sinal.MalformedMeasurements(fields.InvalidField("count", _))) =
    process.receive(failures, 100)
  sinal.emit(ev, 2, Delivered)
  process.receive(runs, 100) |> should.equal(Ok(#(2, Delivered)))
  process.receive(runs, 20) |> should.be_error()
  // Telemetry never saw a failing handler, so it removed nothing.
  process.receive(native_failures, 20) |> should.be_error()
  let _ = ffi.telemetry_detach(listener_id)
  sinal.detach(attachment) |> should.equal(Ok(Nil))
}

pub fn scoped_subscription_and_span_handlers_survive_decode_failures_test() {
  let definition =
    span.define(
      ["decode_failure", "span"],
      start_metadata: incomplete_outcome(),
      stop_measurements: fields.empty(),
      stop_metadata: fields.empty(),
    )
  let events = span.events(definition)
  let starts = process.new_subject()
  let plan =
    sinal.subscriptions([
      sinal.subscription(events.start, fn(_, metadata) {
        process.send(starts, metadata.metadata)
      }),
    ])
  let assert Ok(completion) =
    sinal.with_subscriptions(plan, fn() {
      let _ =
        capture_warnings(fn() {
          span.run(definition, Retried, fn() {
            span.Completion(result: Nil, measurements: Nil, metadata: Nil)
          })
        })
      span.run(definition, Delivered, fn() {
        span.Completion(result: Nil, measurements: Nil, metadata: Nil)
      })
    })
  process.receive(starts, 100) |> should.equal(Ok(Delivered))
  process.receive(starts, 20) |> should.be_error()
  // The handler was still attached when the scope detached it.
  completion.cleanup_failures |> should.equal([])
}

pub fn emit_reports_an_unlisted_enum_value_at_the_emit_site_test() {
  let metadata =
    fields.record({
      use outcome <- fields.parameter
      use previous <- fields.parameter
      #(outcome, previous)
    })
    |> fields.and(incomplete_outcome(), fn(m: #(Outcome, _)) { m.0 })
    |> fields.and(
      fields.optional(fields.enum("previous", [Delivered], outcome_name)),
      fn(m) { m.1 },
    )
    |> fields.build
  let ev =
    sinal.event(["decode_failure", "emit_site"], fields.empty(), metadata)
  let #(Nil, logs) =
    capture_warnings(fn() { sinal.emit(ev, Nil, #(Delivered, None)) })
  logs |> should.equal([])
  let #(Nil, logs) =
    capture_warnings(fn() { sinal.emit(ev, Nil, #(Delivered, Some(Retried))) })
  logs
  |> should.equal([
    "sinal.emit: event [\"decode_failure\", \"emit_site\"] carries a value that its fields.enum list does not name (invalid value at key previous: expected one of delivered, found \"retried\"); every sinal handler of the event will skip it as malformed",
  ])
  // The native map still carries the name, for Erlang and Elixir handlers.
  fields.encode(incomplete_outcome(), Retried)
  |> should.equal(native_map([#("outcome", dynamic.string("retried"))]))
}

/// Runs `work` and returns its result with the text of every warning that
/// sinal logged in this process meanwhile.
@external(erlang, "sinal_log_test_ffi", "capture_warnings")
fn capture_warnings(work: fn() -> a) -> #(a, List(String))

@external(erlang, "scope_test_ffi", "native_map")
fn native_map(pairs: List(#(String, Dynamic))) -> Dynamic

@external(erlang, "scope_test_ffi", "native_emit")
fn native_emit(
  name: List(String),
  measurements: Dynamic,
  metadata: Dynamic,
) -> Nil

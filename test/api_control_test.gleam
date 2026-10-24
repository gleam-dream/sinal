import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
import gleam/list
import gleeunit/should
import sinal
import sinal/fields
import sinal/internal/ffi
import sinal/span

pub type Caught(a) {
  Returned(a)
  CaughtException(String, Dynamic, Dynamic)
}

@external(erlang, "scope_test_ffi", "catch_exception")
fn catch_exception(work: fn() -> a) -> Caught(a)

@external(erlang, "scope_test_ffi", "raise_test_throw")
fn raise_test_throw(reason: String) -> a

@external(erlang, "scope_test_ffi", "term_equals")
fn term_equals(a: Dynamic, b: Dynamic) -> Bool

@external(erlang, "scope_test_ffi", "has_origin_frame")
fn has_origin_frame(
  stacktrace: Dynamic,
  module: String,
  function: String,
) -> Bool

@external(erlang, "scope_test_ffi", "native_map")
fn native_map(pairs: List(#(String, Dynamic))) -> Dynamic

@external(erlang, "scope_test_ffi", "handler_records")
fn handler_records(name: List(String)) -> List(#(Dynamic, atom.Atom))

@external(erlang, "scope_test_ffi", "native_emit")
fn native_emit(
  name: List(String),
  measurements: Dynamic,
  metadata: Dynamic,
) -> Nil

@external(erlang, "scope_test_ffi", "native_to_milliseconds")
fn native_to_milliseconds(value: Int) -> Int

@external(erlang, "scope_test_ffi", "native_to_nanoseconds")
fn native_to_nanoseconds(value: Int) -> Int

pub fn mixed_subscriptions_acquire_and_cleanup_test() {
  let number_event =
    sinal.event(["api_control", "number"], fields.int("number"), fields.empty())
  let name_event =
    sinal.event(
      ["api_control", "name"],
      fields.string("name"),
      fields.bool("active"),
    )
  let subject = process.new_subject()
  let number =
    sinal.subscription(number_event, fn(value, _) {
      process.send(subject, int.to_string(value))
    })
  let name =
    sinal.subscription(name_event, fn(value, active) {
      process.send(
        subject,
        value
          <> ":"
          <> case active {
          True -> "active"
          False -> "inactive"
        },
      )
    })
  let outcome =
    sinal.with_subscriptions(sinal.subscriptions([number, name]), fn() {
      sinal.emit(number_event, 7, Nil)
      sinal.emit(name_event, "Ada", True)
      42
    })
  outcome
  |> should.equal(Ok(sinal.SubscriptionCompletion(42, [])))
  process.receive(subject, 100) |> should.equal(Ok("7"))
  process.receive(subject, 100) |> should.equal(Ok("Ada:active"))
  sinal.emit(number_event, 8, Nil)
  sinal.emit(name_event, "Lin", False)
  process.receive(subject, 20) |> should.be_error()
}

pub fn subscription_acquisition_failure_rolls_back_and_skips_work_test() {
  let first_event =
    sinal.event(["api_control", "rollback_1"], fields.empty(), fields.empty())
  let second_event =
    sinal.event(["api_control", "rollback_2"], fields.empty(), fields.empty())
  let subject = process.new_subject()
  let first =
    sinal.subscription(first_event, fn(_, _) { process.send(subject, "first") })
    |> sinal.with_id("api-control-shared-id")
  let second =
    sinal.subscription(second_event, fn(_, _) { Nil })
    |> sinal.with_id("api-control-shared-id")
  sinal.with_subscriptions(sinal.subscriptions([first, second]), fn() {
    process.send(subject, "work")
  })
  |> should.equal(
    Error(
      sinal.SubscriptionAttachFailed(
        1,
        sinal.AlreadyExists("api-control-shared-id"),
        [],
      ),
    ),
  )
  sinal.emit(first_event, Nil, Nil)
  process.receive(subject, 20) |> should.be_error()
}

pub fn subscription_work_exception_cleans_mixed_handlers_test() {
  let first_event =
    sinal.event(["api_control", "throw_1"], fields.int("x"), fields.empty())
  let second_event =
    sinal.event(["api_control", "throw_2"], fields.string("y"), fields.empty())
  let subject = process.new_subject()
  let caught =
    catch_exception(fn() {
      sinal.with_subscriptions(
        sinal.subscriptions([
          sinal.subscription(first_event, fn(_, _) {
            process.send(subject, "first")
          }),
          sinal.subscription(second_event, fn(_, _) {
            process.send(subject, "second")
          }),
        ]),
        fn() {
          sinal.emit(first_event, 1, Nil)
          sinal.emit(second_event, "a", Nil)
          raise_test_throw("mixed_work_throw")
        },
      )
    })
  case caught {
    CaughtException(class, reason, stacktrace) -> {
      class |> should.equal("throw")
      term_equals(reason, ffi.to_dynamic("mixed_work_throw"))
      |> should.equal(True)
      has_origin_frame(stacktrace, "scope_test_ffi", "raise_test_throw")
      |> should.equal(True)
    }
    Returned(_) -> panic as "expected throw"
  }
  process.receive(subject, 100) |> should.equal(Ok("first"))
  process.receive(subject, 100) |> should.equal(Ok("second"))
  sinal.emit(first_event, 2, Nil)
  sinal.emit(second_event, "b", Nil)
  process.receive(subject, 20) |> should.be_error()
}

pub fn subscription_cleanup_failures_keep_each_index_test() {
  let first_event =
    sinal.event(["api_control", "cleanup_1"], fields.int("x"), fields.empty())
  let second_event =
    sinal.event(
      ["api_control", "cleanup_2"],
      fields.string("y"),
      fields.empty(),
    )
  let first =
    sinal.handler(
      [first_event],
      fn(_, _, _) { Error("first failed") },
      fn(_, _) { Nil },
    )
  let second =
    sinal.handler([second_event], fn(_, _, _) { Error(27) }, fn(_, _) { Nil })
  let result =
    sinal.with_subscriptions(sinal.subscriptions([first, second]), fn() {
      sinal.emit(first_event, 1, Nil)
      sinal.emit(second_event, "name", Nil)
      "work completed"
    })
  result
  |> should.equal(
    Ok(
      sinal.SubscriptionCompletion("work completed", [
        sinal.SubscriptionCleanupFailure(1, sinal.AlreadyDetached),
        sinal.SubscriptionCleanupFailure(0, sinal.AlreadyDetached),
      ]),
    ),
  )
}

pub fn subscription_plan_reports_cleanup_during_work_exception_test() {
  let event =
    sinal.event(
      ["api_control", "cleanup_on_throw"],
      fields.empty(),
      fields.empty(),
    )
  let observer =
    sinal.handler([event], fn(_, _, _) { Error("handler failed") }, fn(_, _) {
      Nil
    })
  let reports = process.new_subject()
  let plan =
    sinal.subscriptions([observer])
    |> sinal.with_exception_cleanup_reporter(fn(failure) {
      process.send(reports, failure)
    })
  let caught =
    catch_exception(fn() {
      sinal.with_subscriptions(plan, fn() {
        sinal.emit(event, Nil, Nil)
        raise_test_throw("work failed after observer removal")
      })
    })
  case caught {
    CaughtException(class, reason, stacktrace) -> {
      class |> should.equal("throw")
      term_equals(reason, ffi.to_dynamic("work failed after observer removal"))
      |> should.equal(True)
      has_origin_frame(stacktrace, "scope_test_ffi", "raise_test_throw")
      |> should.equal(True)
    }
    Returned(_) -> panic as "expected throw"
  }
  process.receive(reports, 100)
  |> should.equal(
    Ok(sinal.SubscriptionCleanupFailure(0, sinal.AlreadyDetached)),
  )
}

pub fn malformed_native_span_timing_reaches_typed_failure_test() {
  let definition =
    span.define(
      ["api_control", "bad_time"],
      start_metadata: fields.empty(),
      stop_measurements: fields.empty(),
      stop_metadata: fields.empty(),
    )
  let events = span.events(definition)
  let subject = process.new_subject()
  let assert Ok(attachment) =
    sinal.attach(
      sinal.handler([events.start], fn(_, _, _) { Ok(Nil) }, fn(_, failure) {
        process.send(subject, failure)
      }),
    )
  native_emit(
    sinal.name(events.start),
    native_map([
      #("system_time", dynamic.string("bad")),
      #("monotonic_time", dynamic.int(10)),
    ]),
    native_map([]),
  )
  let assert Ok(failure) = process.receive(subject, 100)
  case failure {
    sinal.MalformedMeasurements(fields.InvalidField("system_time", _)) -> Nil
    _ -> panic as "expected rejected system_time"
  }
  // A decode failure skips one invocation; the handler stays attached.
  sinal.detach(attachment) |> should.equal(Ok(Nil))
}

pub fn span_duration_conversion_is_explicit_test() {
  let definition =
    span.define(
      ["api_control", "duration"],
      start_metadata: fields.empty(),
      stop_measurements: fields.empty(),
      stop_metadata: fields.empty(),
    )
  let events = span.events(definition)
  let subject = process.new_subject()
  let start_subject = process.new_subject()
  let start_attachment =
    sinal.observe(events.start, fn(measurements, _) {
      process.send(start_subject, measurements)
    })
  let attachment =
    sinal.observe(events.stop, fn(measurements, _) {
      process.send(subject, measurements.duration)
    })
  span.run(definition, Nil, fn() { span.Completion(9, Nil, Nil) })
  |> should.equal(9)
  let assert Ok(start) = process.receive(start_subject, 100)
  let system_time_is_positive =
    span.system_time_in(start.system_time, span.Native) > 0
  system_time_is_positive |> should.equal(True)
  span.monotonic_time_in(start.monotonic_time, span.Nanosecond)
  |> should.equal(
    native_to_nanoseconds(span.monotonic_time_in(
      start.monotonic_time,
      span.Native,
    )),
  )
  let assert Ok(duration) = process.receive(subject, 100)
  native_to_milliseconds(span.duration_in(duration, span.Native))
  |> should.equal(span.duration_in(duration, span.Millisecond))
  let nanos_at_least_micros =
    span.duration_in(duration, span.Nanosecond)
    >= span.duration_in(duration, span.Microsecond) * 1000
  nanos_at_least_micros |> should.equal(True)
  let millis_at_least_seconds =
    span.duration_in(duration, span.Millisecond)
    >= span.duration_in(duration, span.Second) * 1000
  millis_at_least_seconds |> should.equal(True)
  sinal.detach(start_attachment) |> should.equal(Ok(Nil))
  sinal.detach(attachment) |> should.equal(Ok(Nil))
}

pub fn span_run_preserves_native_work_exception_test() {
  let definition =
    span.define(
      ["api_control", "work_throw"],
      start_metadata: fields.empty(),
      stop_measurements: fields.empty(),
      stop_metadata: fields.empty(),
    )
  let events = span.events(definition)
  let reason_subject = process.new_subject()
  let attachment =
    sinal.observe(events.exception, fn(_, metadata) {
      process.send(reason_subject, span.reason_to_dynamic(metadata.reason))
    })
  let caught =
    catch_exception(fn() {
      span.run(definition, Nil, fn() { raise_test_throw("original_span_throw") })
    })
  case caught {
    CaughtException(class, reason, stacktrace) -> {
      class |> should.equal("throw")
      term_equals(reason, ffi.to_dynamic("original_span_throw"))
      |> should.equal(True)
      has_origin_frame(stacktrace, "scope_test_ffi", "raise_test_throw")
      |> should.equal(True)
    }
    Returned(_) -> panic as "expected original work throw"
  }
  let assert Ok(event_reason) = process.receive(reason_subject, 100)
  term_equals(event_reason, ffi.to_dynamic("original_span_throw"))
  |> should.equal(True)
  sinal.detach(attachment) |> should.equal(Ok(Nil))
}

// Every handler gets a fresh id, so two observers of one event coexist
// without the caller naming them, and each is attached as the exported
// `sinal_ffi:handle/4`, which keeps native telemetry on its fast path.
pub fn observe_uses_fresh_ids_and_an_exported_handler_test() {
  let name = ["api_control", "fresh_ids"]
  let event = sinal.event(name, fields.int("n"), fields.empty())
  let subject = process.new_subject()
  let first = sinal.observe(event, fn(n, _) { process.send(subject, #(1, n)) })
  let second = sinal.observe(event, fn(n, _) { process.send(subject, #(2, n)) })
  let named =
    sinal.attach(
      sinal.subscription(event, fn(_, _) { Nil })
      |> sinal.with_id("api-control-named"),
    )
  let assert Ok(named) = named

  let records = handler_records(name)
  records |> list.length |> should.equal(3)
  records
  |> list.all(fn(record) { record.1 == atom.create("external") })
  |> should.be_true()
  records
  |> list.any(fn(record) { record.0 == dynamic.string("api-control-named") })
  |> should.be_true()

  sinal.emit(event, 5, Nil)
  let assert Ok(a) = process.receive(subject, 100)
  let assert Ok(b) = process.receive(subject, 100)
  list.sort([a.0, b.0], int.compare) |> should.equal([1, 2])

  sinal.detach(first) |> should.equal(Ok(Nil))
  sinal.detach(second) |> should.equal(Ok(Nil))
  sinal.detach(named) |> should.equal(Ok(Nil))
  handler_records(name) |> should.equal([])
}

pub fn describe_functions_name_the_failure_test() {
  sinal.describe_attach_error(sinal.AlreadyExists("metrics"))
  |> should.equal("a handler with id \"metrics\" is already attached")
  sinal.describe_handler_failure(sinal.HandlerReturned(3), int.to_string)
  |> should.equal("the handler returned an error: 3")
  sinal.describe_handler_failure(
    sinal.MalformedMetadata(fields.MissingField("route")),
    int.to_string,
  )
  |> should.equal("malformed metadata: missing key route")
  sinal.describe_handler_failure(
    sinal.MalformedMeasurements(fields.NotAMap),
    int.to_string,
  )
  |> should.equal("malformed measurements: expected a native map")
  sinal.describe_cleanup_failure(sinal.AlreadyDetached)
  |> should.equal("the handler was already detached")
  sinal.describe_cleanup_failure(sinal.DetachCrashed("exit: timeout"))
  |> should.equal("detaching crashed: exit: timeout")
  sinal.describe_scope_error(
    sinal.SubscriptionAttachFailed(2, sinal.AlreadyExists("metrics"), [
      sinal.SubscriptionCleanupFailure(0, sinal.AlreadyDetached),
    ]),
  )
  |> should.equal(
    "subscription 2 did not attach: a handler with id \"metrics\" is already attached; rollback failed for subscription 0 (the handler was already detached)",
  )
}

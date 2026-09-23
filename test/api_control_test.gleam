import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleam/erlang/process
import gleam/int
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

@external(erlang, "scope_test_ffi", "is_span_instrumentation_reason")
fn is_span_instrumentation_reason(reason: Dynamic, error: Dynamic) -> Bool

@external(erlang, "scope_test_ffi", "has_span_result_slot")
fn has_span_result_slot() -> Bool

@external(erlang, "scope_test_ffi", "native_to_milliseconds")
fn native_to_milliseconds(value: Int) -> Int

@external(erlang, "scope_test_ffi", "native_to_nanoseconds")
fn native_to_nanoseconds(value: Int) -> Int

pub fn mixed_subscriptions_acquire_and_cleanup_test() {
  let assert Ok(number_event) =
    sinal.event(
      [atom.create("api_control"), atom.create("number")],
      fields.int(atom.create("number")),
      fields.empty(),
    )
  let assert Ok(name_event) =
    sinal.event(
      [atom.create("api_control"), atom.create("name")],
      fields.string(atom.create("name")),
      fields.bool(atom.create("active")),
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
      let assert Ok(Nil) = sinal.emit(number_event, 7, Nil)
      let assert Ok(Nil) = sinal.emit(name_event, "Ada", True)
      42
    })
  outcome
  |> should.equal(Ok(sinal.SubscriptionCompletion(42, [])))
  process.receive(subject, 100) |> should.equal(Ok("7"))
  process.receive(subject, 100) |> should.equal(Ok("Ada:active"))
  let assert Ok(Nil) = sinal.emit(number_event, 8, Nil)
  let assert Ok(Nil) = sinal.emit(name_event, "Lin", False)
  process.receive(subject, 20) |> should.be_error()
}

pub fn subscription_acquisition_failure_rolls_back_and_skips_work_test() {
  let assert Ok(first_event) =
    sinal.event(
      [atom.create("api_control"), atom.create("rollback_1")],
      fields.empty(),
      fields.empty(),
    )
  let assert Ok(second_event) =
    sinal.event(
      [atom.create("api_control"), atom.create("rollback_2")],
      fields.empty(),
      fields.empty(),
    )
  let assert Ok(id) = sinal.handler_id("api-control-shared-id")
  let subject = process.new_subject()
  let first =
    sinal.handler_subscription(
      id,
      first_event,
      fn(_, _, _) {
        process.send(subject, "first")
        Ok(Nil)
      },
      fn(_, _) { Nil },
    )
  let second =
    sinal.handler_subscription(
      id,
      second_event,
      fn(_, _, _) { Ok(Nil) },
      fn(_, _) { Nil },
    )
  sinal.with_subscriptions(sinal.subscriptions([first, second]), fn() {
    process.send(subject, "work")
  })
  |> should.equal(
    Error(sinal.SubscriptionAttachFailed(1, sinal.AlreadyExists, [])),
  )
  let assert Ok(Nil) = sinal.emit(first_event, Nil, Nil)
  process.receive(subject, 20) |> should.be_error()
}

pub fn subscription_work_exception_cleans_mixed_handlers_test() {
  let assert Ok(first_event) =
    sinal.event(
      [atom.create("api_control"), atom.create("throw_1")],
      fields.int(atom.create("x")),
      fields.empty(),
    )
  let assert Ok(second_event) =
    sinal.event(
      [atom.create("api_control"), atom.create("throw_2")],
      fields.string(atom.create("y")),
      fields.empty(),
    )
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
          let assert Ok(Nil) = sinal.emit(first_event, 1, Nil)
          let assert Ok(Nil) = sinal.emit(second_event, "a", Nil)
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
  let assert Ok(Nil) = sinal.emit(first_event, 2, Nil)
  let assert Ok(Nil) = sinal.emit(second_event, "b", Nil)
  process.receive(subject, 20) |> should.be_error()
}

pub fn subscription_cleanup_failures_keep_each_index_test() {
  let assert Ok(first_event) =
    sinal.event(
      [atom.create("api_control"), atom.create("cleanup_1")],
      fields.int(atom.create("x")),
      fields.empty(),
    )
  let assert Ok(second_event) =
    sinal.event(
      [atom.create("api_control"), atom.create("cleanup_2")],
      fields.string(atom.create("y")),
      fields.empty(),
    )
  let assert Ok(first_id) = sinal.handler_id("api-control-cleanup-first")
  let assert Ok(second_id) = sinal.handler_id("api-control-cleanup-second")
  let first =
    sinal.handler_subscription(
      first_id,
      first_event,
      fn(_, _, _) { Error("first failed") },
      fn(_, _) { Nil },
    )
  let second =
    sinal.handler_subscription(
      second_id,
      second_event,
      fn(_, _, _) { Error(27) },
      fn(_, _) { Nil },
    )
  let result =
    sinal.with_subscriptions(sinal.subscriptions([first, second]), fn() {
      let assert Ok(Nil) = sinal.emit(first_event, 1, Nil)
      let assert Ok(Nil) = sinal.emit(second_event, "name", Nil)
      "work completed"
    })
  result
  |> should.equal(
    Ok(
      sinal.SubscriptionCompletion("work completed", [
        sinal.SubscriptionCleanupFailure(
          1,
          sinal.DetachReturnedError(sinal.NotAttached),
        ),
        sinal.SubscriptionCleanupFailure(
          0,
          sinal.DetachReturnedError(sinal.NotAttached),
        ),
      ]),
    ),
  )
}

pub fn subscription_plan_reports_cleanup_during_work_exception_test() {
  let assert Ok(event) =
    sinal.event(
      [atom.create("api_control"), atom.create("cleanup_on_throw")],
      fields.empty(),
      fields.empty(),
    )
  let assert Ok(id) = sinal.handler_id("api-control-cleanup-on-throw")
  let observer =
    sinal.handler_subscription(
      id,
      event,
      fn(_, _, _) { Error("handler failed") },
      fn(_, _) { Nil },
    )
  let reports = process.new_subject()
  let plan =
    sinal.subscriptions([observer])
    |> sinal.with_exception_cleanup_reporter(fn(failure) {
      process.send(reports, failure)
    })
  let caught =
    catch_exception(fn() {
      sinal.with_subscriptions(plan, fn() {
        let assert Ok(Nil) = sinal.emit(event, Nil, Nil)
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
    Ok(sinal.SubscriptionCleanupFailure(
      0,
      sinal.DetachReturnedError(sinal.NotAttached),
    )),
  )
}

pub fn malformed_native_span_timing_reaches_typed_failure_test() {
  let assert Ok(prefix) =
    span.event_prefix([atom.create("api_control"), atom.create("bad_time")])
  let assert Ok(definition) =
    span.define_span(prefix, fields.empty(), fields.empty(), fields.empty())
  let events = span.events(definition)
  let assert Ok(id) = sinal.handler_id("api-control-bad-time")
  let subject = process.new_subject()
  let assert Ok(attachment) =
    sinal.attach(id, events.start, fn(_, _, _) { Ok(Nil) }, fn(_, failure) {
      process.send(subject, failure)
    })
  let bad = ffi.map_from_pair(atom.create("system_time"), ffi.to_dynamic("bad"))
  let measurements =
    ffi.map_merge(
      bad,
      ffi.map_from_pair(atom.create("monotonic_time"), ffi.to_dynamic(10)),
    )
  ffi.telemetry_execute(
    sinal.event_native_name(events.start),
    measurements,
    ffi.empty_map(),
  )
  let assert Ok(failure) = process.receive(subject, 100)
  case failure {
    sinal.MalformedMeasurements(fields.InvalidField("system_time", _)) -> Nil
    _ -> panic as "expected rejected system_time"
  }
  sinal.detach(attachment) |> should.equal(Error(sinal.NotAttached))
}

pub fn span_completion_encoding_failure_retains_result_without_terminal_event_test() {
  let assert Ok(prefix) =
    span.event_prefix([atom.create("api_control"), atom.create("encode_fail")])
  let extra =
    fields.field(
      atom.create("custom"),
      fn(_value: Int) { Error(fields.FieldEncodeError("cannot encode custom")) },
      fn(_) { Ok(0) },
    )
  let assert Ok(definition) =
    span.define_span(prefix, fields.empty(), extra, fields.empty())
  let events = span.events(definition)
  let subject = process.new_subject()
  let reason_subject = process.new_subject()
  let assert Ok(start_id) = sinal.handler_id("api-control-start")
  let assert Ok(stop_id) = sinal.handler_id("api-control-stop")
  let assert Ok(exception_id) = sinal.handler_id("api-control-exception")
  let assert Ok(start_attachment) =
    sinal.observe(start_id, events.start, fn(_, _) {
      process.send(subject, "start")
    })
  let assert Ok(stop_attachment) =
    sinal.observe(stop_id, events.stop, fn(_, _) {
      process.send(subject, "stop")
    })
  let assert Ok(exception_attachment) =
    sinal.observe(exception_id, events.exception, fn(_, metadata) {
      process.send(
        reason_subject,
        span.exception_reason_to_dynamic(metadata.reason),
      )
    })
  let outcome =
    span.run_span_result(definition, Nil, fn() {
      process.send(subject, "work")
      span.Completion("business-result", 5, Nil)
    })
  outcome
  |> should.equal(span.CompletionEncodingFailed(
    "business-result",
    span.ExtraMeasurementsEncodingFailed(fields.FieldEncodeError(
      "cannot encode custom",
    )),
  ))
  process.receive(subject, 100) |> should.equal(Ok("start"))
  process.receive(subject, 100) |> should.equal(Ok("work"))
  process.receive(subject, 20) |> should.be_error()
  let assert Ok(reason) = process.receive(reason_subject, 100)
  is_span_instrumentation_reason(
    reason,
    ffi.to_dynamic(
      span.ExtraMeasurementsEncodingFailed(fields.FieldEncodeError(
        "cannot encode custom",
      )),
    ),
  )
  |> should.equal(True)
  sinal.detach(start_attachment) |> should.equal(Ok(Nil))
  sinal.detach(stop_attachment) |> should.equal(Ok(Nil))
  sinal.detach(exception_attachment) |> should.equal(Ok(Nil))
  has_span_result_slot() |> should.equal(False)
}

pub fn span_start_encoding_failure_skips_work_and_events_test() {
  let assert Ok(prefix) =
    span.event_prefix([atom.create("api_control"), atom.create("start_fail")])
  let start =
    fields.field(
      atom.create("input"),
      fn(_value: Int) { Error(fields.FieldEncodeError("bad start")) },
      fn(_) { Ok(0) },
    )
  let assert Ok(definition) =
    span.define_span(prefix, start, fields.empty(), fields.empty())
  let events = span.events(definition)
  let subject = process.new_subject()
  let assert Ok(id) = sinal.handler_id("api-control-start-fail")
  let assert Ok(attachment) =
    sinal.observe(id, events.start, fn(_, _) { process.send(subject, "start") })
  span.run_span_result(definition, 1, fn() {
    process.send(subject, "work")
    span.Completion("never", Nil, Nil)
  })
  |> should.equal(
    span.StartEncodingFailed(fields.FieldEncodeError("bad start")),
  )
  process.receive(subject, 20) |> should.be_error()
  sinal.detach(attachment) |> should.equal(Ok(Nil))
}

pub fn span_duration_conversion_is_explicit_test() {
  let assert Ok(prefix) =
    span.event_prefix([atom.create("api_control"), atom.create("duration")])
  let assert Ok(definition) =
    span.define_span(prefix, fields.empty(), fields.empty(), fields.empty())
  let events = span.events(definition)
  let subject = process.new_subject()
  let start_subject = process.new_subject()
  let assert Ok(id) = sinal.handler_id("api-control-duration")
  let assert Ok(start_id) = sinal.handler_id("api-control-start-times")
  let assert Ok(start_attachment) =
    sinal.observe(start_id, events.start, fn(measurements, _) {
      process.send(start_subject, measurements)
    })
  let assert Ok(attachment) =
    sinal.observe(id, events.stop, fn(measurements, _) {
      process.send(subject, measurements.duration)
    })
  span.run_span_result(definition, Nil, fn() { span.Completion(9, Nil, Nil) })
  |> should.equal(span.SpanCompleted(9))
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

pub fn nested_span_encoding_failures_keep_distinct_results_and_clean_slots_test() {
  let assert Ok(outer_prefix) =
    span.event_prefix([atom.create("api_control"), atom.create("nested_outer")])
  let assert Ok(inner_prefix) =
    span.event_prefix([atom.create("api_control"), atom.create("nested_inner")])
  let failing =
    fields.field(
      atom.create("extra"),
      fn(_value: Int) { Error(fields.FieldEncodeError("bad extra")) },
      fn(_) { Ok(0) },
    )
  let assert Ok(outer) =
    span.define_span(outer_prefix, fields.empty(), failing, fields.empty())
  let assert Ok(inner) =
    span.define_span(inner_prefix, fields.empty(), failing, fields.empty())
  let result =
    span.run_span_result(outer, Nil, fn() {
      let inner_result =
        span.run_span_result(inner, Nil, fn() {
          span.Completion("inner", 1, Nil)
        })
      inner_result
      |> should.equal(span.CompletionEncodingFailed(
        "inner",
        span.ExtraMeasurementsEncodingFailed(fields.FieldEncodeError(
          "bad extra",
        )),
      ))
      span.Completion("outer", 2, Nil)
    })
  result
  |> should.equal(span.CompletionEncodingFailed(
    "outer",
    span.ExtraMeasurementsEncodingFailed(fields.FieldEncodeError("bad extra")),
  ))
  has_span_result_slot() |> should.equal(False)
}

pub fn span_result_preserves_native_work_exception_test() {
  let assert Ok(prefix) =
    span.event_prefix([atom.create("api_control"), atom.create("work_throw")])
  let assert Ok(definition) =
    span.define_span(prefix, fields.empty(), fields.empty(), fields.empty())
  let events = span.events(definition)
  let reason_subject = process.new_subject()
  let assert Ok(id) = sinal.handler_id("api-control-work-throw")
  let assert Ok(attachment) =
    sinal.observe(id, events.exception, fn(_, metadata) {
      process.send(
        reason_subject,
        span.exception_reason_to_dynamic(metadata.reason),
      )
    })
  let caught =
    catch_exception(fn() {
      span.run_span_result(definition, Nil, fn() {
        raise_test_throw("original_span_throw")
      })
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
  has_span_result_slot() |> should.equal(False)
  sinal.detach(attachment) |> should.equal(Ok(Nil))
}

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleeunit
import gleeunit/should
import sinal
import sinal/fields
import sinal/internal/ffi
import sinal/span

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn version_test() {
  sinal.version()
  |> should.equal("0.1.0")
}

pub fn handler_id_validation_test() {
  sinal.handler_id("")
  |> should.equal(Error(sinal.EmptyHandlerId))

  sinal.handler_id("valid-handler-id")
  |> should.be_ok()
}

pub fn event_empty_name_rejection_test() {
  let empty = fields.empty()

  // Empty event name is rejected
  sinal.event([], empty, empty)
  |> should.equal(Error(sinal.EmptyEventName))

  // Non-empty event name succeeds
  let atom_ev = atom.create("valid_event")
  let assert Ok(ev) = sinal.event([atom_ev], empty, empty)
  sinal.event_name(ev)
  |> should.equal(["valid_event"])
}

pub fn span_empty_prefix_rejection_test() {
  span.event_prefix([])
  |> should.equal(Error(span.EmptyPrefix))

  let prefix_atom = atom.create("http")
  let assert Ok(prefix) = span.event_prefix([prefix_atom])
  span.prefix_name(prefix)
  |> should.equal(["http"])
}

pub fn fields_composition_and_duplicate_native_key_rejection_test() {
  let key_a = atom.create("field_a")
  let key_b = atom.create("field_b")

  let field_a =
    fields.field(key_a, fn(n: Int) { Ok(dynamic.int(n)) }, fn(dyn) {
      case decode.run(dyn, decode.int) {
        Ok(n) -> Ok(n)
        Error(_) -> Error(fields.FieldDecodeError("expected int"))
      }
    })

  let field_b =
    fields.field(key_b, fn(s: String) { Ok(dynamic.string(s)) }, fn(dyn) {
      case decode.run(dyn, decode.string) {
        Ok(s) -> Ok(s)
        Error(_) -> Error(fields.FieldDecodeError("expected string"))
      }
    })

  // Pairing distinct native atom keys succeeds
  fields.pair(field_a, field_b)
  |> should.be_ok()

  // Pairing identical native atom keys fails with DuplicateField
  fields.pair(field_a, field_a)
  |> should.equal(Error(fields.DuplicateField("field_a")))
}

pub fn fallible_field_encoding_propagation_test() {
  let key = atom.create("fallible_field")

  let field =
    fields.field(
      key,
      fn(n: Int) {
        case n < 0 {
          True -> Error(fields.FieldEncodeError("cannot be negative"))
          False -> Ok(dynamic.int(n))
        }
      },
      fn(_) { Ok(0) },
    )

  // Valid encode returns Ok(map)
  fields.encode(field, 10)
  |> should.be_ok()

  // Invalid encode propagates Error(FieldEncodeError)
  fields.encode(field, -5)
  |> should.equal(Error(fields.FieldEncodeError("cannot be negative")))
}

pub fn empty_fields_rejects_non_map_boundary_test() {
  let empty = fields.empty()

  // Empty fields decodes valid native map successfully
  fields.decode(empty, ffi.empty_map())
  |> should.equal(Ok(Nil))

  // Empty fields rejects non-map Dynamic at the boundary
  fields.decode(empty, dynamic.int(42))
  |> should.equal(
    Error(fields.InvalidField(
      "",
      fields.FieldDecodeError("Expected a native BEAM map"),
    )),
  )

  fields.decode(empty, dynamic.string("not_a_map"))
  |> should.equal(
    Error(fields.InvalidField(
      "",
      fields.FieldDecodeError("Expected a native BEAM map"),
    )),
  )
}

pub fn validate_event_names_duplicate_native_rejection_test() {
  let atom_a = atom.create("event_a")
  let atom_b = atom.create("event_b")
  let empty = fields.empty()

  let assert Ok(ev_a1) = sinal.trusted_event([atom_a], empty, empty)
  let assert Ok(ev_a2) = sinal.trusted_event([atom_a], empty, empty)
  let assert Ok(ev_b) = sinal.trusted_event([atom_b], empty, empty)

  // Disjoint event names succeed
  sinal.validate_event_names(ev_a1, [ev_b])
  |> should.equal(Ok(Nil))

  // Duplicate native event names are rejected
  sinal.validate_event_names(ev_a1, [ev_a2])
  |> should.equal(Error(sinal.DuplicateEventName(["event_a"])))
}

pub fn span_reserved_field_rejection_test() {
  let assert Ok(prefix) = span.trusted_prefix([atom.create("test_prefix")])
  let empty = fields.empty()

  let duration_atom = atom.create("duration")
  let reserved_duration_field =
    fields.field(duration_atom, fn(n: Int) { Ok(dynamic.int(n)) }, fn(_) {
      Ok(0)
    })

  span.define_span(prefix, empty, reserved_duration_field, empty)
  |> should.equal(Error(span.ReservedMeasurementField("duration")))

  let context_atom = atom.create("telemetry_span_context")
  let reserved_context_field =
    fields.field(context_atom, fn(s: String) { Ok(dynamic.string(s)) }, fn(_) {
      Ok("")
    })

  span.define_span(prefix, reserved_context_field, empty, empty)
  |> should.equal(Error(span.ReservedMetadataField("telemetry_span_context")))
}

pub fn native_attach_and_emit_synchronous_delivery_test() {
  let key_count = atom.create("delivery_count")
  let key_user = atom.create("delivery_user")
  let field_count =
    fields.field(key_count, fn(n: Int) { Ok(dynamic.int(n)) }, fn(dyn) {
      case decode.run(dyn, decode.int) {
        Ok(n) -> Ok(n)
        Error(_) -> Error(fields.FieldDecodeError("expected int"))
      }
    })
  let field_user =
    fields.field(key_user, fn(s: String) { Ok(dynamic.string(s)) }, fn(dyn) {
      case decode.run(dyn, decode.string) {
        Ok(s) -> Ok(s)
        Error(_) -> Error(fields.FieldDecodeError("expected string"))
      }
    })
  let assert Ok(ev) =
    sinal.event(
      [atom.create("test"), atom.create("sync"), atom.create("delivery")],
      field_count,
      field_user,
    )
  let assert Ok(hid) = sinal.handler_id("sync-delivery-handler")
  let parent = process.self()
  let subject = process.new_subject()
  let handler =
    sinal.handler(fn(selected_ev, count: Int, user: String) {
      let calling_pid = process.self()
      process.send(subject, #(
        sinal.event_name(selected_ev),
        count,
        user,
        calling_pid,
      ))
      Ok(Nil)
    })
  let assert Ok(att) = sinal.attach(hid, ev, handler, fn(_, _) { Nil })
  let assert Ok(Nil) = sinal.emit(ev, 100, "bob")
  let assert Ok(#(ev_name, count, user, calling_pid)) =
    process.receive(subject, 100)
  ev_name |> should.equal(["test", "sync", "delivery"])
  count |> should.equal(100)
  user |> should.equal("bob")
  calling_pid |> should.equal(parent)
  sinal.detach(att) |> should.equal(Ok(Nil))
}

pub fn duplicate_handler_id_rejection_test() {
  let empty = fields.empty()
  let assert Ok(ev) =
    sinal.event([atom.create("test"), atom.create("dup_id")], empty, empty)
  let assert Ok(hid) = sinal.handler_id("duplicate-id-test")
  let handler = sinal.handler(fn(_, _, _) { Ok(Nil) })
  let assert Ok(att) = sinal.attach(hid, ev, handler, fn(_, _) { Nil })
  sinal.attach(hid, ev, handler, fn(_, _) { Nil })
  |> should.equal(Error(sinal.AlreadyExists))
  sinal.detach(att) |> should.equal(Ok(Nil))
}

pub fn detach_and_repeated_detach_test() {
  let empty = fields.empty()
  let assert Ok(ev) =
    sinal.event(
      [atom.create("test"), atom.create("repeated_detach")],
      empty,
      empty,
    )
  let assert Ok(hid) = sinal.handler_id("repeated-detach-test")
  let subject = process.new_subject()
  let handler =
    sinal.handler(fn(_, _, _) {
      process.send(subject, Nil)
      Ok(Nil)
    })
  let assert Ok(att) = sinal.attach(hid, ev, handler, fn(_, _) { Nil })
  sinal.detach(att) |> should.equal(Ok(Nil))
  sinal.detach(att) |> should.equal(Error(sinal.NotAttached))
  // After detach, emitting should not invoke the handler
  let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
  process.receive(subject, 50) |> should.be_error()
}

pub fn attach_many_multi_event_descriptor_selection_test() {
  let empty = fields.empty()
  let assert Ok(ev_a) =
    sinal.event(
      [atom.create("test"), atom.create("multi"), atom.create("a")],
      empty,
      empty,
    )
  let assert Ok(ev_b) =
    sinal.event(
      [atom.create("test"), atom.create("multi"), atom.create("b")],
      empty,
      empty,
    )
  let assert Ok(hid) = sinal.handler_id("attach-many-selection-test")
  let subject = process.new_subject()
  let handler =
    sinal.handler(fn(selected_ev, _, _) {
      process.send(subject, sinal.event_name(selected_ev))
      Ok(Nil)
    })
  let assert Ok(att) =
    sinal.attach_many(hid, ev_a, [ev_b], handler, fn(_, _) { Nil })
  let assert Ok(Nil) = sinal.emit(ev_a, Nil, Nil)
  process.receive(subject, 100)
  |> should.equal(Ok(["test", "multi", "a"]))
  let assert Ok(Nil) = sinal.emit(ev_b, Nil, Nil)
  process.receive(subject, 100)
  |> should.equal(Ok(["test", "multi", "b"]))
  sinal.detach(att) |> should.equal(Ok(Nil))
}

pub fn encode_refusal_invokes_no_native_dispatch_test() {
  let key = atom.create("strict_val")
  let strict_field =
    fields.field(
      key,
      fn(n: Int) {
        case n >= 0 {
          True -> Ok(dynamic.int(n))
          False -> Error(fields.FieldEncodeError("negative prohibited"))
        }
      },
      fn(_) { Ok(0) },
    )
  let assert Ok(ev) =
    sinal.event(
      [atom.create("test"), atom.create("encode_refusal")],
      strict_field,
      fields.empty(),
    )
  let assert Ok(hid) = sinal.handler_id("encode-refusal-handler")
  let subject = process.new_subject()
  let handler =
    sinal.handler(fn(_, _, _) {
      process.send(subject, Nil)
      Ok(Nil)
    })
  let assert Ok(att) = sinal.attach(hid, ev, handler, fn(_, _) { Nil })
  // Negative value fails encode
  sinal.emit(ev, -1, Nil)
  |> should.equal(
    Error(sinal.EncodingFailed(fields.FieldEncodeError("negative prohibited"))),
  )
  // Proves no native dispatch occurred
  process.receive(subject, 50) |> should.be_error()
  sinal.detach(att) |> should.equal(Ok(Nil))
}

pub fn malformed_measurements_invokes_failure_observer_and_removes_handler_test() {
  let key = atom.create("int_field")
  let int_field =
    fields.field(key, fn(n: Int) { Ok(dynamic.int(n)) }, fn(dyn) {
      case decode.run(dyn, decode.int) {
        Ok(n) -> Ok(n)
        Error(_) -> Error(fields.FieldDecodeError("expected int"))
      }
    })
  let ev_name = [atom.create("test"), atom.create("malformed_meas")]
  let assert Ok(ev) = sinal.event(ev_name, int_field, fields.empty())
  let assert Ok(hid) = sinal.handler_id("malformed-meas-handler")
  let failure_subject = process.new_subject()
  let on_failure = fn(selected_ev, failure) {
    process.send(failure_subject, #(sinal.event_name(selected_ev), failure))
  }
  let handler = sinal.handler(fn(_, _, _) { Ok(Nil) })
  let assert Ok(att) = sinal.attach(hid, ev, handler, on_failure)

  // Listen for native telemetry [telemetry, handler, failure]
  let failure_event = [
    atom.create("telemetry"),
    atom.create("handler"),
    atom.create("failure"),
  ]
  let listener_id =
    ffi.to_dynamic(atom.create("telemetry_failure_listener_meas"))
  let telemetry_failure_subject = process.new_subject()
  let listener_cb = fn(ev_name, measurements, metadata, _config) {
    let rec = decode_failure_event(measurements, metadata)
    process.send(telemetry_failure_subject, #(ev_name, rec))
  }
  let assert Ok(Nil) =
    ffi.telemetry_attach_many(
      listener_id,
      [failure_event],
      listener_cb,
      ffi.to_dynamic(Nil),
    )

  // Emit raw foreign event with bad measurement (string instead of int)
  let bad_measurements = ffi.map_from_pair(key, dynamic.string("not_an_int"))
  ffi.telemetry_execute(ev_name, bad_measurements, ffi.empty_map())

  // on_failure called with MalformedMeasurements
  let assert Ok(#(ev_label, failure)) = process.receive(failure_subject, 100)
  ev_label |> should.equal(["test", "malformed_meas"])
  case failure {
    sinal.MalformedMeasurements(_) -> Nil
    _ -> panic as "expected MalformedMeasurements"
  }

  // Upstream failure event occurred with full contract payload
  let assert Ok(#(actual_failure_ev_name, rec)) =
    process.receive(telemetry_failure_subject, 100)
  actual_failure_ev_name
  |> should.equal([
    atom.create("telemetry"),
    atom.create("handler"),
    atom.create("failure"),
  ])
  rec.has_valid_times |> should.equal(True)
  rec.event_name |> should.equal(["test", "malformed_meas"])
  rec.kind |> should.equal("error")
  is_callback_failure_reason(rec.reason, "malformed_measurements")
  |> should.equal(True)
  rec.has_stacktrace |> should.equal(True)
  term_equals(rec.handler_id, ffi.to_dynamic(hid)) |> should.equal(True)
  term_equals(rec.handler_config, ffi.to_dynamic(Nil)) |> should.equal(True)
  let _ = ffi.telemetry_detach(listener_id)

  // Handler is detached as consequence of failure
  sinal.detach(att) |> should.equal(Error(sinal.NotAttached))
}

pub fn malformed_metadata_invokes_failure_observer_and_removes_handler_test() {
  let key = atom.create("str_meta")
  let str_field =
    fields.field(key, fn(s: String) { Ok(dynamic.string(s)) }, fn(dyn) {
      case decode.run(dyn, decode.string) {
        Ok(s) -> Ok(s)
        Error(_) -> Error(fields.FieldDecodeError("expected string"))
      }
    })
  let ev_name = [atom.create("test"), atom.create("malformed_meta")]
  let assert Ok(ev) = sinal.event(ev_name, fields.empty(), str_field)
  let assert Ok(hid) = sinal.handler_id("malformed-meta-handler")
  let failure_subject = process.new_subject()
  let on_failure = fn(selected_ev, failure) {
    process.send(failure_subject, #(sinal.event_name(selected_ev), failure))
  }
  let handler = sinal.handler(fn(_, _, _) { Ok(Nil) })
  let assert Ok(att) = sinal.attach(hid, ev, handler, on_failure)

  // Listen for native telemetry [telemetry, handler, failure]
  let failure_event = [
    atom.create("telemetry"),
    atom.create("handler"),
    atom.create("failure"),
  ]
  let listener_id =
    ffi.to_dynamic(atom.create("telemetry_failure_listener_meta"))
  let telemetry_failure_subject = process.new_subject()
  let listener_cb = fn(ev_name, measurements, metadata, _config) {
    let rec = decode_failure_event(measurements, metadata)
    process.send(telemetry_failure_subject, #(ev_name, rec))
  }
  let assert Ok(Nil) =
    ffi.telemetry_attach_many(
      listener_id,
      [failure_event],
      listener_cb,
      ffi.to_dynamic(Nil),
    )

  // Emit raw foreign event with bad metadata (int instead of string)
  let bad_metadata = ffi.map_from_pair(key, dynamic.int(999))
  ffi.telemetry_execute(ev_name, ffi.empty_map(), bad_metadata)

  let assert Ok(#(ev_label, failure)) = process.receive(failure_subject, 100)
  ev_label |> should.equal(["test", "malformed_meta"])
  case failure {
    sinal.MalformedMetadata(_) -> Nil
    _ -> panic as "expected MalformedMetadata"
  }

  let assert Ok(#(actual_failure_ev_name, rec)) =
    process.receive(telemetry_failure_subject, 100)
  actual_failure_ev_name
  |> should.equal([
    atom.create("telemetry"),
    atom.create("handler"),
    atom.create("failure"),
  ])
  rec.has_valid_times |> should.equal(True)
  rec.event_name |> should.equal(["test", "malformed_meta"])
  rec.kind |> should.equal("error")
  is_callback_failure_reason(rec.reason, "malformed_metadata")
  |> should.equal(True)
  rec.has_stacktrace |> should.equal(True)
  term_equals(rec.handler_id, ffi.to_dynamic(hid)) |> should.equal(True)
  term_equals(rec.handler_config, ffi.to_dynamic(Nil)) |> should.equal(True)
  let _ = ffi.telemetry_detach(listener_id)

  sinal.detach(att) |> should.equal(Error(sinal.NotAttached))
}

pub fn handler_returned_error_invokes_failure_observer_and_removes_handler_test() {
  let empty = fields.empty()
  let ev_name = [atom.create("test"), atom.create("handler_error")]
  let assert Ok(ev) = sinal.event(ev_name, empty, empty)
  let assert Ok(hid) = sinal.handler_id("handler-return-error-test")
  let failure_subject = process.new_subject()
  let on_failure = fn(selected_ev, failure) {
    process.send(failure_subject, #(sinal.event_name(selected_ev), failure))
  }
  let handler = sinal.handler(fn(_, _, _) { Error("simulated business error") })
  let assert Ok(att) = sinal.attach(hid, ev, handler, on_failure)

  let failure_event = [
    atom.create("telemetry"),
    atom.create("handler"),
    atom.create("failure"),
  ]
  let listener_id =
    ffi.to_dynamic(atom.create("telemetry_failure_listener_return"))
  let telemetry_failure_subject = process.new_subject()
  let listener_cb = fn(ev_name, measurements, metadata, _config) {
    let rec = decode_failure_event(measurements, metadata)
    process.send(telemetry_failure_subject, #(ev_name, rec))
  }
  let assert Ok(Nil) =
    ffi.telemetry_attach_many(
      listener_id,
      [failure_event],
      listener_cb,
      ffi.to_dynamic(Nil),
    )

  let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)

  let assert Ok(#(ev_label, failure)) = process.receive(failure_subject, 100)
  ev_label |> should.equal(["test", "handler_error"])
  failure |> should.equal(sinal.HandlerReturned("simulated business error"))

  let assert Ok(#(actual_failure_ev_name, rec)) =
    process.receive(telemetry_failure_subject, 100)
  actual_failure_ev_name
  |> should.equal([
    atom.create("telemetry"),
    atom.create("handler"),
    atom.create("failure"),
  ])
  rec.has_valid_times |> should.equal(True)
  rec.event_name |> should.equal(["test", "handler_error"])
  rec.kind |> should.equal("error")
  is_callback_failure_reason(rec.reason, "handler_returned_error")
  |> should.equal(True)
  rec.has_stacktrace |> should.equal(True)
  term_equals(rec.handler_id, ffi.to_dynamic(hid)) |> should.equal(True)
  term_equals(rec.handler_config, ffi.to_dynamic(Nil)) |> should.equal(True)
  let _ = ffi.telemetry_detach(listener_id)

  sinal.detach(att) |> should.equal(Error(sinal.NotAttached))
}

pub fn unexpected_callback_crash_not_converted_to_typed_error_test() {
  let empty = fields.empty()
  let ev_name = [atom.create("test"), atom.create("crash_not_converted")]
  let assert Ok(ev) = sinal.event(ev_name, empty, empty)
  let assert Ok(hid) = sinal.handler_id("unexpected-crash-handler")
  let failure_subject = process.new_subject()
  let on_failure = fn(_, failure) { process.send(failure_subject, failure) }
  let handler =
    sinal.handler(fn(_, _, _) {
      // Panic causes an untyped BEAM exception
      panic as "unexpected crash"
    })
  let assert Ok(att) = sinal.attach(hid, ev, handler, on_failure)

  let failure_event = [
    atom.create("telemetry"),
    atom.create("handler"),
    atom.create("failure"),
  ]
  let listener_id =
    ffi.to_dynamic(atom.create("telemetry_failure_listener_crash"))
  let telemetry_failure_subject = process.new_subject()
  let listener_cb = fn(ev_name, measurements, metadata, _config) {
    let rec = decode_failure_event(measurements, metadata)
    process.send(telemetry_failure_subject, #(ev_name, rec))
  }
  let assert Ok(Nil) =
    ffi.telemetry_attach_many(
      listener_id,
      [failure_event],
      listener_cb,
      ffi.to_dynamic(Nil),
    )

  // Emitter receives Ok(Nil) — subscriber crash is isolated
  sinal.emit(ev, Nil, Nil) |> should.equal(Ok(Nil))

  // on_failure was NOT called because crash was untyped BEAM exception
  process.receive(failure_subject, 50) |> should.be_error()

  // Upstream failure event fired with original panic reason
  let assert Ok(#(actual_failure_ev_name, rec)) =
    process.receive(telemetry_failure_subject, 100)
  actual_failure_ev_name
  |> should.equal([
    atom.create("telemetry"),
    atom.create("handler"),
    atom.create("failure"),
  ])
  rec.has_valid_times |> should.equal(True)
  rec.event_name |> should.equal(["test", "crash_not_converted"])
  rec.kind |> should.equal("error")
  is_panic_reason(rec.reason, "unexpected crash") |> should.equal(True)
  rec.has_stacktrace |> should.equal(True)
  term_equals(rec.handler_id, ffi.to_dynamic(hid)) |> should.equal(True)
  term_equals(rec.handler_config, ffi.to_dynamic(Nil)) |> should.equal(True)
  let _ = ffi.telemetry_detach(listener_id)

  // Handler was removed
  sinal.detach(att) |> should.equal(Error(sinal.NotAttached))
}

pub fn foreign_raw_emission_with_extra_fields_tolerated_test() {
  let key = atom.create("target_count")
  let count_field =
    fields.field(key, fn(n: Int) { Ok(dynamic.int(n)) }, fn(dyn) {
      case decode.run(dyn, decode.int) {
        Ok(n) -> Ok(n)
        Error(_) -> Error(fields.FieldDecodeError("expected int"))
      }
    })
  let ev_name = [atom.create("test"), atom.create("foreign_extra_fields")]
  let assert Ok(ev) = sinal.event(ev_name, count_field, fields.empty())
  let assert Ok(hid) = sinal.handler_id("foreign-extra-fields-handler")
  let subject = process.new_subject()
  let handler =
    sinal.handler(fn(_, count: Int, _) {
      process.send(subject, count)
      Ok(Nil)
    })
  let assert Ok(att) = sinal.attach(hid, ev, handler, fn(_, _) { Nil })

  // Create native map with target_count PLUS unknown extra keys
  let base_map = ffi.map_from_pair(key, dynamic.int(777))
  let extra_map =
    ffi.map_from_pair(
      atom.create("unknown_foreign_key"),
      dynamic.string("extra"),
    )
  let merged_map = ffi.map_merge(base_map, extra_map)

  ffi.telemetry_execute(ev_name, merged_map, ffi.empty_map())

  process.receive(subject, 100) |> should.equal(Ok(777))
  sinal.detach(att) |> should.equal(Ok(Nil))
}

pub type CatchOutcome(a) {
  Returned(value: a)
  CaughtException(class: String, reason: Dynamic, stacktrace: Dynamic)
}

pub type TelemetryFailureRecord {
  TelemetryFailureRecord(
    has_valid_times: Bool,
    monotonic_time: Int,
    system_time: Int,
    event_name: List(String),
    handler_id: Dynamic,
    handler_config: Dynamic,
    kind: String,
    reason: Dynamic,
    has_stacktrace: Bool,
  )
}

@external(erlang, "scope_test_ffi", "catch_exception")
fn catch_exception(fun: fn() -> a) -> CatchOutcome(a)

@external(erlang, "scope_test_ffi", "raise_test_error")
fn raise_test_error(reason: a) -> b

@external(erlang, "scope_test_ffi", "raise_test_exit")
fn raise_test_exit(reason: a) -> b

@external(erlang, "scope_test_ffi", "raise_test_throw")
fn raise_test_throw(reason: a) -> b

@external(erlang, "scope_test_ffi", "is_stacktrace_list")
fn is_stacktrace_list(stacktrace: Dynamic) -> Bool

@external(erlang, "scope_test_ffi", "decode_failure_event")
fn decode_failure_event(
  measurements: Dynamic,
  metadata: Dynamic,
) -> TelemetryFailureRecord

@external(erlang, "scope_test_ffi", "is_callback_failure_reason")
fn is_callback_failure_reason(reason: Dynamic, expected: String) -> Bool

@external(erlang, "scope_test_ffi", "is_panic_reason")
fn is_panic_reason(reason: Dynamic, expected: String) -> Bool

@external(erlang, "scope_test_ffi", "term_equals")
fn term_equals(a: Dynamic, b: Dynamic) -> Bool

@external(erlang, "scope_test_ffi", "telemetry_persist")
fn telemetry_persist() -> Nil

@external(erlang, "scope_test_ffi", "sleep")
fn sleep(ms: Int) -> Nil

@external(erlang, "scope_test_ffi", "is_native_integer")
fn is_native_integer(term: Dynamic) -> Bool

@external(erlang, "scope_test_ffi", "is_positive_integer")
fn is_positive_integer(term: Dynamic) -> Bool

@external(erlang, "scope_test_ffi", "is_non_negative_integer")
fn is_non_negative_integer(term: Dynamic) -> Bool

@external(erlang, "scope_test_ffi", "is_native_reference")
fn is_native_reference(term: Dynamic) -> Bool

@external(erlang, "scope_test_ffi", "has_origin_frame")
fn has_origin_frame(
  stacktrace: Dynamic,
  module: String,
  function: String,
) -> Bool

pub fn scoped_lifetime_ordinary_completion_test() {
  let empty = fields.empty()
  let ev_name = [atom.create("scope"), atom.create("ordinary")]
  let assert Ok(ev) = sinal.event(ev_name, empty, empty)
  let subject = process.new_subject()
  let handler =
    sinal.handler(fn(_, _, _) {
      process.send(subject, "handler_called")
      Ok(Nil)
    })

  let result =
    sinal.with_attachments(
      ev,
      [],
      handler,
      fn(_, _) { Nil },
      fn(_) { Nil },
      fn() {
        let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
        "work_value"
      },
    )

  result
  |> should.equal(
    Ok(sinal.ScopedCompletion(
      work_result: "work_value",
      cleanup_result: Ok(Nil),
    )),
  )
  process.receive(subject, 100) |> should.equal(Ok("handler_called"))

  // After scope completion, handler is detached
  let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
  process.receive(subject, 50) |> should.be_error()
}

pub fn scoped_lifetime_attach_refusal_test() {
  let empty = fields.empty()
  let ev_name = [atom.create("scope"), atom.create("dup")]
  let assert Ok(ev1) = sinal.trusted_event(ev_name, empty, empty)
  let assert Ok(ev2) = sinal.trusted_event(ev_name, empty, empty)
  let subject = process.new_subject()
  let handler = sinal.handler(fn(_, _, _) { Ok(Nil) })

  let result =
    sinal.with_attachments(
      ev1,
      [ev2],
      handler,
      fn(_, _) { Nil },
      fn(_) { Nil },
      fn() {
        process.send(subject, "should_not_run")
        "work"
      },
    )

  result |> should.equal(Error(sinal.DuplicateEventName(["scope", "dup"])))
  process.receive(subject, 50) |> should.be_error()
}

pub fn scoped_lifetime_exceptional_work_cleanup_and_reraise_test() {
  let empty = fields.empty()
  let ev_name = [atom.create("scope"), atom.create("exceptional")]
  let assert Ok(ev) = sinal.event(ev_name, empty, empty)

  // 1. erlang:error/1 fidelity
  let subject_err = process.new_subject()
  let handler_err =
    sinal.handler(fn(_, _, _) {
      process.send(subject_err, "called_before_crash")
      Ok(Nil)
    })
  let caught_err =
    catch_exception(fn() {
      sinal.with_attachments(
        ev,
        [],
        handler_err,
        fn(_, _) { Nil },
        fn(_) { Nil },
        fn() {
          let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
          raise_test_error("work_failure_error")
        },
      )
    })
  case caught_err {
    CaughtException(class, reason, stacktrace) -> {
      class |> should.equal("error")
      term_equals(reason, ffi.to_dynamic("work_failure_error"))
      |> should.equal(True)
      is_stacktrace_list(stacktrace) |> should.equal(True)
      has_origin_frame(stacktrace, "scope_test_ffi", "raise_test_error")
      |> should.equal(True)
    }
    Returned(_) -> panic as "expected caught error exception"
  }
  process.receive(subject_err, 100) |> should.equal(Ok("called_before_crash"))
  let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
  process.receive(subject_err, 50) |> should.be_error()

  // 2. erlang:exit/1 fidelity
  let subject_exit = process.new_subject()
  let handler_exit =
    sinal.handler(fn(_, _, _) {
      process.send(subject_exit, "called_before_exit")
      Ok(Nil)
    })
  let caught_exit =
    catch_exception(fn() {
      sinal.with_attachments(
        ev,
        [],
        handler_exit,
        fn(_, _) { Nil },
        fn(_) { Nil },
        fn() {
          let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
          raise_test_exit("work_failure_exit")
        },
      )
    })
  case caught_exit {
    CaughtException(class, reason, stacktrace) -> {
      class |> should.equal("exit")
      term_equals(reason, ffi.to_dynamic("work_failure_exit"))
      |> should.equal(True)
      is_stacktrace_list(stacktrace) |> should.equal(True)
      has_origin_frame(stacktrace, "scope_test_ffi", "raise_test_exit")
      |> should.equal(True)
    }
    Returned(_) -> panic as "expected caught exit exception"
  }
  process.receive(subject_exit, 100) |> should.equal(Ok("called_before_exit"))
  let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
  process.receive(subject_exit, 50) |> should.be_error()

  // 3. erlang:throw/1 fidelity
  let subject_throw = process.new_subject()
  let handler_throw =
    sinal.handler(fn(_, _, _) {
      process.send(subject_throw, "called_before_throw")
      Ok(Nil)
    })
  let caught_throw =
    catch_exception(fn() {
      sinal.with_attachments(
        ev,
        [],
        handler_throw,
        fn(_, _) { Nil },
        fn(_) { Nil },
        fn() {
          let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
          raise_test_throw("work_failure_throw")
        },
      )
    })
  case caught_throw {
    CaughtException(class, reason, stacktrace) -> {
      class |> should.equal("throw")
      term_equals(reason, ffi.to_dynamic("work_failure_throw"))
      |> should.equal(True)
      is_stacktrace_list(stacktrace) |> should.equal(True)
      has_origin_frame(stacktrace, "scope_test_ffi", "raise_test_throw")
      |> should.equal(True)
    }
    Returned(_) -> panic as "expected caught throw exception"
  }
  process.receive(subject_throw, 100) |> should.equal(Ok("called_before_throw"))
  let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
  process.receive(subject_throw, 50) |> should.be_error()
}

pub fn scoped_lifetime_cleanup_error_does_not_mask_work_exception_test() {
  let empty = fields.empty()
  let ev_name = [atom.create("scope"), atom.create("cleanup_err_mask")]
  let assert Ok(ev) = sinal.event(ev_name, empty, empty)
  let cleanup_failure_subject = process.new_subject()

  let handler =
    sinal.handler(fn(_, _, _) {
      // Handler failure removes it from telemetry
      Error("fail_and_remove_for_detach_error")
    })
  let on_cleanup_failure = fn(failure) {
    process.send(cleanup_failure_subject, failure)
  }

  // Work throws while cleanup encounters DetachReturnedError(NotAttached)
  let caught =
    catch_exception(fn() {
      sinal.with_attachments(
        ev,
        [],
        handler,
        fn(_, _) { Nil },
        on_cleanup_failure,
        fn() {
          let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
          raise_test_throw("work_throw_with_cleanup_error")
        },
      )
    })

  let assert Ok(failure) = process.receive(cleanup_failure_subject, 100)
  failure |> should.equal(sinal.DetachReturnedError(sinal.NotAttached))

  case caught {
    CaughtException(class, reason, stacktrace) -> {
      class |> should.equal("throw")
      term_equals(reason, ffi.to_dynamic("work_throw_with_cleanup_error"))
      |> should.equal(True)
      is_stacktrace_list(stacktrace) |> should.equal(True)
      has_origin_frame(stacktrace, "scope_test_ffi", "raise_test_throw")
      |> should.equal(True)
    }
    Returned(_) -> panic as "expected work throw to be preserved"
  }
}

pub fn scoped_lifetime_cleanup_reporter_failure_does_not_mask_work_exception_test() {
  let empty = fields.empty()
  let ev_name = [atom.create("scope"), atom.create("reporter_fail")]
  let assert Ok(ev) = sinal.event(ev_name, empty, empty)
  let cleanup_failure_subject = process.new_subject()

  let handler =
    sinal.handler(fn(_, _, _) {
      // Cause handler failure so telemetry removes it before scope exit
      Error("fail_and_remove")
    })

  let on_cleanup_failure = fn(failure) {
    process.send(cleanup_failure_subject, failure)
    // Panicking inside reporter must not mask original work exception
    panic as "reporter_panicked"
  }

  // 1. Error class work exception with reporter panic
  let caught_err =
    catch_exception(fn() {
      sinal.with_attachments(
        ev,
        [],
        handler,
        fn(_, _) { Nil },
        on_cleanup_failure,
        fn() {
          let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
          raise_test_error("original_work_error")
        },
      )
    })
  let assert Ok(failure) = process.receive(cleanup_failure_subject, 100)
  failure |> should.equal(sinal.DetachReturnedError(sinal.NotAttached))
  case caught_err {
    CaughtException(class, reason, stacktrace) -> {
      class |> should.equal("error")
      term_equals(reason, ffi.to_dynamic("original_work_error"))
      |> should.equal(True)
      is_stacktrace_list(stacktrace) |> should.equal(True)
      has_origin_frame(stacktrace, "scope_test_ffi", "raise_test_error")
      |> should.equal(True)
    }
    Returned(_) -> panic as "expected caught error exception"
  }

  // 2. Exit class work exception with reporter panic
  let caught_exit =
    catch_exception(fn() {
      sinal.with_attachments(
        ev,
        [],
        handler,
        fn(_, _) { Nil },
        on_cleanup_failure,
        fn() {
          let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
          raise_test_exit("original_work_exit")
        },
      )
    })
  let assert Ok(failure) = process.receive(cleanup_failure_subject, 100)
  failure |> should.equal(sinal.DetachReturnedError(sinal.NotAttached))
  case caught_exit {
    CaughtException(class, reason, stacktrace) -> {
      class |> should.equal("exit")
      term_equals(reason, ffi.to_dynamic("original_work_exit"))
      |> should.equal(True)
      is_stacktrace_list(stacktrace) |> should.equal(True)
      has_origin_frame(stacktrace, "scope_test_ffi", "raise_test_exit")
      |> should.equal(True)
    }
    Returned(_) -> panic as "expected caught exit exception"
  }

  // 3. Throw class work exception with reporter panic
  let caught_throw =
    catch_exception(fn() {
      sinal.with_attachments(
        ev,
        [],
        handler,
        fn(_, _) { Nil },
        on_cleanup_failure,
        fn() {
          let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
          raise_test_throw("original_work_throw")
        },
      )
    })
  let assert Ok(failure) = process.receive(cleanup_failure_subject, 100)
  failure |> should.equal(sinal.DetachReturnedError(sinal.NotAttached))
  case caught_throw {
    CaughtException(class, reason, stacktrace) -> {
      class |> should.equal("throw")
      term_equals(reason, ffi.to_dynamic("original_work_throw"))
      |> should.equal(True)
      is_stacktrace_list(stacktrace) |> should.equal(True)
      has_origin_frame(stacktrace, "scope_test_ffi", "raise_test_throw")
      |> should.equal(True)
    }
    Returned(_) -> panic as "expected caught throw exception"
  }
}

pub fn scoped_lifetime_nested_identity_test() {
  let empty = fields.empty()
  let ev_name = [atom.create("scope"), atom.create("nested")]
  let assert Ok(ev) = sinal.event(ev_name, empty, empty)
  let outer_subject = process.new_subject()
  let inner_subject = process.new_subject()

  let outer_handler =
    sinal.handler(fn(_, _, _) {
      process.send(outer_subject, "outer")
      Ok(Nil)
    })
  let inner_handler =
    sinal.handler(fn(_, _, _) {
      process.send(inner_subject, "inner")
      Ok(Nil)
    })

  let outer_res =
    sinal.with_attachments(
      ev,
      [],
      outer_handler,
      fn(_, _) { Nil },
      fn(_) { Nil },
      fn() {
        let inner_res =
          sinal.with_attachments(
            ev,
            [],
            inner_handler,
            fn(_, _) { Nil },
            fn(_) { Nil },
            fn() {
              // Emit while both are active
              let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
              "inner_done"
            },
          )
        inner_res
        |> should.equal(
          Ok(sinal.ScopedCompletion(
            work_result: "inner_done",
            cleanup_result: Ok(Nil),
          )),
        )
        // Emit after inner exited — only outer should receive
        let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
        "outer_done"
      },
    )

  outer_res
  |> should.equal(
    Ok(sinal.ScopedCompletion(
      work_result: "outer_done",
      cleanup_result: Ok(Nil),
    )),
  )

  // Inner received 1 event
  process.receive(inner_subject, 100) |> should.equal(Ok("inner"))
  process.receive(inner_subject, 50) |> should.be_error()

  // Outer received 2 events
  process.receive(outer_subject, 100) |> should.equal(Ok("outer"))
  process.receive(outer_subject, 100) |> should.equal(Ok("outer"))
  process.receive(outer_subject, 50) |> should.be_error()
}

pub fn scoped_lifetime_already_removed_not_attached_test() {
  let empty = fields.empty()
  let ev_name = [atom.create("scope"), atom.create("already_removed")]
  let assert Ok(ev) = sinal.event(ev_name, empty, empty)

  let handler =
    sinal.handler(fn(_, _, _) {
      // Cause handler failure so telemetry detaches it
      Error("fail_handler")
    })

  let result =
    sinal.with_attachments(
      ev,
      [],
      handler,
      fn(_, _) { Nil },
      fn(_) { Nil },
      fn() {
        let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
        "work_survived"
      },
    )

  result
  |> should.equal(
    Ok(sinal.ScopedCompletion(
      work_result: "work_survived",
      cleanup_result: Error(sinal.DetachReturnedError(sinal.NotAttached)),
    )),
  )
}

pub fn remove_all_handler_on_failure_across_events_test() {
  let empty = fields.empty()
  let ev1_name = [atom.create("multi_fail"), atom.create("ev1")]
  let ev2_name = [atom.create("multi_fail"), atom.create("ev2")]
  let assert Ok(ev1) = sinal.event(ev1_name, empty, empty)
  let assert Ok(ev2) = sinal.event(ev2_name, empty, empty)

  // 1. Failure via erlang:error/1 removes handler from every registered event
  let assert Ok(hid_err) = sinal.handler_id("multi-fail-err")
  let ev2_called_err = process.new_subject()
  let handler_err =
    sinal.handler(fn(selected_ev, _, _) {
      case sinal.event_name(selected_ev) {
        ["multi_fail", "ev1"] -> raise_test_error("fail_on_ev1_error")
        _ -> {
          process.send(ev2_called_err, "called")
          Ok(Nil)
        }
      }
    })
  let assert Ok(att_err) =
    sinal.attach_many(hid_err, ev1, [ev2], handler_err, fn(_, _) { Nil })

  sinal.emit(ev1, Nil, Nil) |> should.equal(Ok(Nil))
  sinal.emit(ev2, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(ev2_called_err, 50) |> should.be_error()
  sinal.detach(att_err) |> should.equal(Error(sinal.NotAttached))

  // 2. Failure via erlang:exit/1 removes handler from every registered event
  let assert Ok(hid_exit) = sinal.handler_id("multi-fail-exit")
  let ev2_called_exit = process.new_subject()
  let handler_exit =
    sinal.handler(fn(selected_ev, _, _) {
      case sinal.event_name(selected_ev) {
        ["multi_fail", "ev1"] -> raise_test_exit("fail_on_ev1_exit")
        _ -> {
          process.send(ev2_called_exit, "called")
          Ok(Nil)
        }
      }
    })
  let assert Ok(att_exit) =
    sinal.attach_many(hid_exit, ev1, [ev2], handler_exit, fn(_, _) { Nil })

  sinal.emit(ev1, Nil, Nil) |> should.equal(Ok(Nil))
  sinal.emit(ev2, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(ev2_called_exit, 50) |> should.be_error()
  sinal.detach(att_exit) |> should.equal(Error(sinal.NotAttached))

  // 3. Failure via erlang:throw/1 removes handler from every registered event
  let assert Ok(hid_throw) = sinal.handler_id("multi-fail-throw")
  let ev2_called_throw = process.new_subject()
  let handler_throw =
    sinal.handler(fn(selected_ev, _, _) {
      case sinal.event_name(selected_ev) {
        ["multi_fail", "ev1"] -> raise_test_throw("fail_on_ev1_throw")
        _ -> {
          process.send(ev2_called_throw, "called")
          Ok(Nil)
        }
      }
    })
  let assert Ok(att_throw) =
    sinal.attach_many(hid_throw, ev1, [ev2], handler_throw, fn(_, _) { Nil })

  sinal.emit(ev1, Nil, Nil) |> should.equal(Ok(Nil))
  sinal.emit(ev2, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(ev2_called_throw, 50) |> should.be_error()
  sinal.detach(att_throw) |> should.equal(Error(sinal.NotAttached))
}

pub type SpanTestStartMetadata {
  SpanTestStartMetadata(method: String, route: String)
}

pub type SpanTestExtraMeasurements {
  SpanTestExtraMeasurements(bytes: Int)
}

pub type SpanTestStopMetadata {
  SpanTestStopMetadata(status: Int)
}

fn create_test_span() -> span.Span(
  SpanTestStartMetadata,
  SpanTestExtraMeasurements,
  SpanTestStopMetadata,
) {
  let prefix = [atom.create("test_span"), atom.create("op")]
  let assert Ok(p) = span.event_prefix(prefix)

  let method_field =
    fields.field(
      atom.create("method"),
      fn(m) { Ok(dynamic.string(m)) },
      fn(dyn) {
        case decode.run(dyn, decode.string) {
          Ok(s) -> Ok(s)
          Error(_) -> Error(fields.FieldDecodeError("expected string"))
        }
      },
    )
  let route_field =
    fields.field(atom.create("route"), fn(r) { Ok(dynamic.string(r)) }, fn(dyn) {
      case decode.run(dyn, decode.string) {
        Ok(s) -> Ok(s)
        Error(_) -> Error(fields.FieldDecodeError("expected string"))
      }
    })
  let assert Ok(start_meta_pair) = fields.pair(method_field, route_field)
  let start_meta =
    fields.imap(
      start_meta_pair,
      fn(pair) { SpanTestStartMetadata(pair.0, pair.1) },
      fn(m: SpanTestStartMetadata) { #(m.method, m.route) },
    )

  let extra_meas =
    fields.field(
      atom.create("bytes"),
      fn(b: SpanTestExtraMeasurements) { Ok(dynamic.int(b.bytes)) },
      fn(dyn) {
        case decode.run(dyn, decode.int) {
          Ok(n) -> Ok(SpanTestExtraMeasurements(n))
          Error(_) -> Error(fields.FieldDecodeError("expected int"))
        }
      },
    )

  let stop_meta =
    fields.field(
      atom.create("status"),
      fn(s: SpanTestStopMetadata) { Ok(dynamic.int(s.status)) },
      fn(dyn) {
        case decode.run(dyn, decode.int) {
          Ok(n) -> Ok(SpanTestStopMetadata(n))
          Error(_) -> Error(fields.FieldDecodeError("expected int"))
        }
      },
    )

  let assert Ok(sp) = span.define_span(p, start_meta, extra_meas, stop_meta)
  sp
}

pub fn span_events_derivation_test() {
  let sp = create_test_span()
  let events = span.events(sp)
  sinal.event_name(events.start) |> should.equal(["test_span", "op", "start"])
  sinal.event_name(events.stop) |> should.equal(["test_span", "op", "stop"])
  sinal.event_name(events.exception)
  |> should.equal(["test_span", "op", "exception"])
}

pub fn run_span_ordinary_success_test() {
  let sp = create_test_span()
  let events = span.events(sp)

  let start_subject = process.new_subject()
  let stop_subject = process.new_subject()

  let start_handler =
    sinal.handler(
      fn(
        _ev,
        meas: span.StartMeasurements,
        meta: span.StartMetadata(SpanTestStartMetadata),
      ) {
        process.send(start_subject, #(meas, meta))
        Ok(Nil)
      },
    )
  let stop_handler =
    sinal.handler(
      fn(
        _ev,
        meas: span.StopMeasurements(SpanTestExtraMeasurements),
        meta: span.StopMetadata(SpanTestStopMetadata),
      ) {
        process.send(stop_subject, #(meas, meta))
        Ok(Nil)
      },
    )

  let assert Ok(hid1) = sinal.handler_id("span-success-start-handler")
  let assert Ok(hid2) = sinal.handler_id("span-success-stop-handler")
  let assert Ok(att1) =
    sinal.attach(hid1, events.start, start_handler, fn(_, _) { Nil })
  let assert Ok(att2) =
    sinal.attach(hid2, events.stop, stop_handler, fn(_, _) { Nil })

  let result =
    span.run_span(
      sp,
      SpanTestStartMetadata(method: "GET", route: "/api/items"),
      fn() {
        span.Completion(
          result: Ok("item_123"),
          measurements: SpanTestExtraMeasurements(bytes: 1024),
          metadata: SpanTestStopMetadata(status: 200),
        )
      },
    )

  result |> should.equal(Ok("item_123"))

  let assert Ok(#(start_meas, start_meta)) = process.receive(start_subject, 100)
  start_meta.metadata.method |> should.equal("GET")
  start_meta.metadata.route |> should.equal("/api/items")
  is_positive_integer(span.system_time_to_dynamic(start_meas.system_time))
  |> should.equal(True)
  is_native_integer(span.monotonic_time_to_dynamic(start_meas.monotonic_time))
  |> should.equal(True)

  let assert Ok(#(stop_meas, stop_meta)) = process.receive(stop_subject, 100)
  stop_meas.extra.bytes |> should.equal(1024)
  stop_meta.metadata.status |> should.equal(200)
  is_non_negative_integer(span.duration_to_dynamic(stop_meas.duration))
  |> should.equal(True)
  is_native_integer(span.monotonic_time_to_dynamic(stop_meas.monotonic_time))
  |> should.equal(True)

  // Context equality within one invocation and native reference check
  is_native_reference(span.span_context_to_dynamic(start_meta.context))
  |> should.equal(True)
  is_native_reference(span.span_context_to_dynamic(stop_meta.context))
  |> should.equal(True)
  start_meta.context |> should.equal(stop_meta.context)
  term_equals(
    span.span_context_to_dynamic(start_meta.context),
    span.span_context_to_dynamic(stop_meta.context),
  )
  |> should.equal(True)

  sinal.detach(att1) |> should.equal(Ok(Nil))
  sinal.detach(att2) |> should.equal(Ok(Nil))
}

pub fn run_span_business_error_as_stop_test() {
  let sp = create_test_span()
  let events = span.events(sp)

  let stop_subject = process.new_subject()
  let exception_subject = process.new_subject()

  let stop_handler =
    sinal.handler(fn(_ev, _meas, meta: span.StopMetadata(SpanTestStopMetadata)) {
      process.send(stop_subject, meta.metadata.status)
      Ok(Nil)
    })
  let exception_handler =
    sinal.handler(fn(_ev, _meas, _meta) {
      process.send(exception_subject, "exception_called")
      Ok(Nil)
    })

  let assert Ok(hid_stop) = sinal.handler_id("span-biz-err-stop-handler")
  let assert Ok(hid_exc) = sinal.handler_id("span-biz-err-exc-handler")
  let assert Ok(att_stop) =
    sinal.attach(hid_stop, events.stop, stop_handler, fn(_, _) { Nil })
  let assert Ok(att_exc) =
    sinal.attach(hid_exc, events.exception, exception_handler, fn(_, _) { Nil })

  let result =
    span.run_span(
      sp,
      SpanTestStartMetadata(method: "POST", route: "/orders"),
      fn() {
        span.Completion(
          result: Error("order_validation_failed"),
          measurements: SpanTestExtraMeasurements(bytes: 0),
          metadata: SpanTestStopMetadata(status: 422),
        )
      },
    )

  // Returns business error directly
  result |> should.equal(Error("order_validation_failed"))

  // Stop event was emitted with status 422
  process.receive(stop_subject, 100) |> should.equal(Ok(422))

  // Exception event was NOT emitted
  process.receive(exception_subject, 50) |> should.be_error()

  sinal.detach(att_stop) |> should.equal(Ok(Nil))
  sinal.detach(att_exc) |> should.equal(Ok(Nil))
}

pub fn run_span_distinct_contexts_across_invocations_test() {
  let sp = create_test_span()
  let events = span.events(sp)
  let context_subject = process.new_subject()

  let start_handler =
    sinal.handler(
      fn(_ev, _meas, meta: span.StartMetadata(SpanTestStartMetadata)) {
        process.send(context_subject, meta.context)
        Ok(Nil)
      },
    )
  let assert Ok(hid) = sinal.handler_id("span-ctx-dist-handler")
  let assert Ok(att) =
    sinal.attach(hid, events.start, start_handler, fn(_, _) { Nil })

  let _ =
    span.run_span(sp, SpanTestStartMetadata("GET", "/first"), fn() {
      span.Completion(
        Ok(1),
        SpanTestExtraMeasurements(0),
        SpanTestStopMetadata(200),
      )
    })
  let assert Ok(ctx1) = process.receive(context_subject, 100)

  let _ =
    span.run_span(sp, SpanTestStartMetadata("GET", "/second"), fn() {
      span.Completion(
        Ok(2),
        SpanTestExtraMeasurements(0),
        SpanTestStopMetadata(200),
      )
    })
  let assert Ok(ctx2) = process.receive(context_subject, 100)

  // Contexts across distinct invocations must differ and be native references
  let dyn1 = span.span_context_to_dynamic(ctx1)
  let dyn2 = span.span_context_to_dynamic(ctx2)
  is_native_reference(dyn1) |> should.equal(True)
  is_native_reference(dyn2) |> should.equal(True)
  ctx1 |> should.not_equal(ctx2)
  term_equals(dyn1, dyn2) |> should.equal(False)

  sinal.detach(att) |> should.equal(Ok(Nil))
}

pub fn run_span_exception_reraise_and_event_test() {
  let sp = create_test_span()
  let events = span.events(sp)

  let start_subject = process.new_subject()
  let stop_subject = process.new_subject()
  let exc_subject = process.new_subject()

  let start_handler =
    sinal.handler(
      fn(_ev, _meas, meta: span.StartMetadata(SpanTestStartMetadata)) {
        process.send(start_subject, meta)
        Ok(Nil)
      },
    )
  let stop_handler =
    sinal.handler(fn(_ev, _meas, _meta) {
      process.send(stop_subject, "stop_fired")
      Ok(Nil)
    })
  let exc_handler =
    sinal.handler(
      fn(
        _ev,
        meas: span.ExceptionMeasurements,
        meta: span.ExceptionMetadata(SpanTestStartMetadata),
      ) {
        process.send(exc_subject, #(meas, meta))
        Ok(Nil)
      },
    )

  let assert Ok(hid1) = sinal.handler_id("span-exc-start-handler")
  let assert Ok(hid2) = sinal.handler_id("span-exc-stop-handler")
  let assert Ok(hid3) = sinal.handler_id("span-exc-exc-handler")
  let assert Ok(att1) =
    sinal.attach(hid1, events.start, start_handler, fn(_, _) { Nil })
  let assert Ok(att2) =
    sinal.attach(hid2, events.stop, stop_handler, fn(_, _) { Nil })
  let assert Ok(att3) =
    sinal.attach(hid3, events.exception, exc_handler, fn(_, _) { Nil })

  // 1. Error class
  let caught_err =
    catch_exception(fn() {
      span.run_span(sp, SpanTestStartMetadata("POST", "/fail-error"), fn() {
        raise_test_error("fatal_span_error")
      })
    })
  let caught_err_stack = case caught_err {
    CaughtException(class, reason, stacktrace) -> {
      class |> should.equal("error")
      term_equals(reason, ffi.to_dynamic("fatal_span_error"))
      |> should.equal(True)
      is_stacktrace_list(stacktrace) |> should.equal(True)
      has_origin_frame(stacktrace, "scope_test_ffi", "raise_test_error")
      |> should.equal(True)
      stacktrace
    }
    Returned(_) -> panic as "expected error exception"
  }
  let assert Ok(start_meta_err) = process.receive(start_subject, 100)
  let assert Ok(#(meas_err, exc_meta_err)) = process.receive(exc_subject, 100)
  exc_meta_err.kind |> should.equal(span.ExceptionError)
  exc_meta_err.context |> should.equal(start_meta_err.context)
  is_non_negative_integer(span.duration_to_dynamic(meas_err.duration))
  |> should.equal(True)
  is_native_integer(span.monotonic_time_to_dynamic(meas_err.monotonic_time))
  |> should.equal(True)
  is_native_reference(span.span_context_to_dynamic(exc_meta_err.context))
  |> should.equal(True)
  term_equals(
    span.span_context_to_dynamic(start_meta_err.context),
    span.span_context_to_dynamic(exc_meta_err.context),
  )
  |> should.equal(True)
  term_equals(
    span.exception_stacktrace_to_dynamic(exc_meta_err.stacktrace),
    caught_err_stack,
  )
  |> should.equal(True)
  has_origin_frame(
    span.exception_stacktrace_to_dynamic(exc_meta_err.stacktrace),
    "scope_test_ffi",
    "raise_test_error",
  )
  |> should.equal(True)
  term_equals(
    span.exception_reason_to_dynamic(exc_meta_err.reason),
    ffi.to_dynamic("fatal_span_error"),
  )
  |> should.equal(True)
  process.receive(stop_subject, 50) |> should.be_error()

  // 2. Exit class
  let caught_exit =
    catch_exception(fn() {
      span.run_span(sp, SpanTestStartMetadata("POST", "/fail-exit"), fn() {
        raise_test_exit("fatal_span_exit")
      })
    })
  let caught_exit_stack = case caught_exit {
    CaughtException(class, reason, stacktrace) -> {
      class |> should.equal("exit")
      term_equals(reason, ffi.to_dynamic("fatal_span_exit"))
      |> should.equal(True)
      is_stacktrace_list(stacktrace) |> should.equal(True)
      has_origin_frame(stacktrace, "scope_test_ffi", "raise_test_exit")
      |> should.equal(True)
      stacktrace
    }
    Returned(_) -> panic as "expected exit exception"
  }
  let assert Ok(start_meta_exit) = process.receive(start_subject, 100)
  let assert Ok(#(meas_exit, exc_meta_exit)) = process.receive(exc_subject, 100)
  exc_meta_exit.kind |> should.equal(span.ExceptionExit)
  exc_meta_exit.context |> should.equal(start_meta_exit.context)
  is_non_negative_integer(span.duration_to_dynamic(meas_exit.duration))
  |> should.equal(True)
  is_native_integer(span.monotonic_time_to_dynamic(meas_exit.monotonic_time))
  |> should.equal(True)
  is_native_reference(span.span_context_to_dynamic(exc_meta_exit.context))
  |> should.equal(True)
  term_equals(
    span.span_context_to_dynamic(start_meta_exit.context),
    span.span_context_to_dynamic(exc_meta_exit.context),
  )
  |> should.equal(True)
  term_equals(
    span.exception_stacktrace_to_dynamic(exc_meta_exit.stacktrace),
    caught_exit_stack,
  )
  |> should.equal(True)
  has_origin_frame(
    span.exception_stacktrace_to_dynamic(exc_meta_exit.stacktrace),
    "scope_test_ffi",
    "raise_test_exit",
  )
  |> should.equal(True)
  term_equals(
    span.exception_reason_to_dynamic(exc_meta_exit.reason),
    ffi.to_dynamic("fatal_span_exit"),
  )
  |> should.equal(True)
  process.receive(stop_subject, 50) |> should.be_error()

  // 3. Throw class
  let caught_throw =
    catch_exception(fn() {
      span.run_span(sp, SpanTestStartMetadata("POST", "/fail-throw"), fn() {
        raise_test_throw("fatal_span_throw")
      })
    })
  let caught_throw_stack = case caught_throw {
    CaughtException(class, reason, stacktrace) -> {
      class |> should.equal("throw")
      term_equals(reason, ffi.to_dynamic("fatal_span_throw"))
      |> should.equal(True)
      is_stacktrace_list(stacktrace) |> should.equal(True)
      has_origin_frame(stacktrace, "scope_test_ffi", "raise_test_throw")
      |> should.equal(True)
      stacktrace
    }
    Returned(_) -> panic as "expected throw exception"
  }
  let assert Ok(start_meta_throw) = process.receive(start_subject, 100)
  let assert Ok(#(meas_throw, exc_meta_throw)) =
    process.receive(exc_subject, 100)
  exc_meta_throw.kind |> should.equal(span.ExceptionThrow)
  exc_meta_throw.context |> should.equal(start_meta_throw.context)
  is_non_negative_integer(span.duration_to_dynamic(meas_throw.duration))
  |> should.equal(True)
  is_native_integer(span.monotonic_time_to_dynamic(meas_throw.monotonic_time))
  |> should.equal(True)
  is_native_reference(span.span_context_to_dynamic(exc_meta_throw.context))
  |> should.equal(True)
  term_equals(
    span.span_context_to_dynamic(start_meta_throw.context),
    span.span_context_to_dynamic(exc_meta_throw.context),
  )
  |> should.equal(True)
  term_equals(
    span.exception_stacktrace_to_dynamic(exc_meta_throw.stacktrace),
    caught_throw_stack,
  )
  |> should.equal(True)
  has_origin_frame(
    span.exception_stacktrace_to_dynamic(exc_meta_throw.stacktrace),
    "scope_test_ffi",
    "raise_test_throw",
  )
  |> should.equal(True)
  term_equals(
    span.exception_reason_to_dynamic(exc_meta_throw.reason),
    ffi.to_dynamic("fatal_span_throw"),
  )
  |> should.equal(True)
  process.receive(stop_subject, 50) |> should.be_error()

  // Prove no second exception event remains after final throw case
  process.receive(exc_subject, 50) |> should.be_error()

  sinal.detach(att1) |> should.equal(Ok(Nil))
  sinal.detach(att2) |> should.equal(Ok(Nil))
  sinal.detach(att3) |> should.equal(Ok(Nil))
}

pub fn run_span_nested_ordering_test() {
  let outer_span = create_test_span()
  let inner_prefix = [atom.create("inner_span"), atom.create("call")]
  let assert Ok(p) = span.event_prefix(inner_prefix)
  let assert Ok(inner_span) =
    span.define_span(p, fields.empty(), fields.empty(), fields.empty())

  let outer_events = span.events(outer_span)
  let inner_events = span.events(inner_span)

  let order_subject = process.new_subject()

  let outer_start_handler =
    sinal.handler(
      fn(_ev, _meas, meta: span.StartMetadata(SpanTestStartMetadata)) {
        process.send(order_subject, #("outer_start", meta.context))
        Ok(Nil)
      },
    )
  let outer_stop_handler =
    sinal.handler(fn(_ev, _meas, meta: span.StopMetadata(SpanTestStopMetadata)) {
      process.send(order_subject, #("outer_stop", meta.context))
      Ok(Nil)
    })
  let inner_start_handler =
    sinal.handler(fn(_ev, _meas, meta: span.StartMetadata(Nil)) {
      process.send(order_subject, #("inner_start", meta.context))
      Ok(Nil)
    })
  let inner_stop_handler =
    sinal.handler(fn(_ev, _meas, meta: span.StopMetadata(Nil)) {
      process.send(order_subject, #("inner_stop", meta.context))
      Ok(Nil)
    })

  let assert Ok(h1) = sinal.handler_id("nested-outer-start")
  let assert Ok(h2) = sinal.handler_id("nested-outer-stop")
  let assert Ok(h3) = sinal.handler_id("nested-inner-start")
  let assert Ok(h4) = sinal.handler_id("nested-inner-stop")

  let assert Ok(a1) =
    sinal.attach(h1, outer_events.start, outer_start_handler, fn(_, _) { Nil })
  let assert Ok(a2) =
    sinal.attach(h2, outer_events.stop, outer_stop_handler, fn(_, _) { Nil })
  let assert Ok(a3) =
    sinal.attach(h3, inner_events.start, inner_start_handler, fn(_, _) { Nil })
  let assert Ok(a4) =
    sinal.attach(h4, inner_events.stop, inner_stop_handler, fn(_, _) { Nil })

  let res =
    span.run_span(outer_span, SpanTestStartMetadata("GET", "/parent"), fn() {
      let inner_res =
        span.run_span(inner_span, Nil, fn() {
          span.Completion(Ok("nested_done"), Nil, Nil)
        })
      span.Completion(
        result: inner_res,
        measurements: SpanTestExtraMeasurements(50),
        metadata: SpanTestStopMetadata(200),
      )
    })

  res |> should.equal(Ok("nested_done"))

  let assert Ok(#("outer_start", outer_ctx1)) =
    process.receive(order_subject, 100)
  let assert Ok(#("inner_start", inner_ctx1)) =
    process.receive(order_subject, 100)
  let assert Ok(#("inner_stop", inner_ctx2)) =
    process.receive(order_subject, 100)
  let assert Ok(#("outer_stop", outer_ctx2)) =
    process.receive(order_subject, 100)

  // Inner start and stop share inner context
  inner_ctx1 |> should.equal(inner_ctx2)
  // Outer start and stop share outer context
  outer_ctx1 |> should.equal(outer_ctx2)
  // Inner context differs from outer context
  outer_ctx1 |> should.not_equal(inner_ctx1)

  sinal.detach(a1) |> should.equal(Ok(Nil))
  sinal.detach(a2) |> should.equal(Ok(Nil))
  sinal.detach(a3) |> should.equal(Ok(Nil))
  sinal.detach(a4) |> should.equal(Ok(Nil))
}

pub fn raw_telemetry_handler_observes_sinal_emission_test() {
  let ev_name = [atom.create("raw_boundary"), atom.create("sinal_to_raw")]
  let key = atom.create("value")
  let val_field =
    fields.field(key, fn(n: Int) { Ok(dynamic.int(n)) }, fn(dyn) {
      case decode.run(dyn, decode.int) {
        Ok(n) -> Ok(n)
        Error(_) -> Error(fields.FieldDecodeError("expected int"))
      }
    })
  let assert Ok(ev) = sinal.event(ev_name, val_field, fields.empty())

  let subject = process.new_subject()
  let listener_id = ffi.to_dynamic(atom.create("raw_listener_for_sinal"))
  let listener_cb = fn(_name, measurements, _meta, _config) {
    let val = case ffi.map_get(measurements, key) {
      Ok(v) -> v
      Error(Nil) -> ffi.to_dynamic(-1)
    }
    process.send(subject, val)
  }
  let assert Ok(Nil) =
    ffi.telemetry_attach_many(
      listener_id,
      [ev_name],
      listener_cb,
      ffi.to_dynamic(Nil),
    )

  sinal.emit(ev, 888, Nil) |> should.equal(Ok(Nil))

  let assert Ok(received_val) = process.receive(subject, 100)
  term_equals(received_val, dynamic.int(888)) |> should.equal(True)

  let _ = ffi.telemetry_detach(listener_id)
}

pub fn sinal_handler_observes_raw_telemetry_emission_test() {
  let ev_name = [atom.create("raw_boundary"), atom.create("raw_to_sinal")]
  let key = atom.create("count")
  let count_field =
    fields.field(key, fn(n: Int) { Ok(dynamic.int(n)) }, fn(dyn) {
      case decode.run(dyn, decode.int) {
        Ok(n) -> Ok(n)
        Error(_) -> Error(fields.FieldDecodeError("expected int"))
      }
    })
  let assert Ok(ev) = sinal.event(ev_name, count_field, fields.empty())
  let assert Ok(hid) = sinal.handler_id("sinal-observing-raw")
  let subject = process.new_subject()

  let handler =
    sinal.handler(fn(_ev, count: Int, _meta) {
      process.send(subject, count)
      Ok(Nil)
    })
  let assert Ok(att) = sinal.attach(hid, ev, handler, fn(_, _) { Nil })

  let raw_map = ffi.map_from_pair(key, dynamic.int(999))
  ffi.telemetry_execute(ev_name, raw_map, ffi.empty_map())

  process.receive(subject, 100) |> should.equal(Ok(999))

  sinal.detach(att) |> should.equal(Ok(Nil))
}

pub fn synchronous_execution_in_caller_pid_and_slow_handler_blocks_test() {
  let ev_name = [atom.create("sync_test"), atom.create("blocking")]
  let empty = fields.empty()
  let assert Ok(ev) = sinal.event(ev_name, empty, empty)
  let assert Ok(hid) = sinal.handler_id("sync-blocking-handler")
  let subject = process.new_subject()

  let handler =
    sinal.handler(fn(_ev, _meas, _meta) {
      sleep(25)
      process.send(subject, "handler_finished")
      Ok(Nil)
    })
  let assert Ok(att) = sinal.attach(hid, ev, handler, fn(_, _) { Nil })

  // When emit returns, the slow handler has already finished
  sinal.emit(ev, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(subject, 10) |> should.equal(Ok("handler_finished"))

  sinal.detach(att) |> should.equal(Ok(Nil))
}

pub fn concurrent_emitters_test() {
  let ev_name = [atom.create("concurrency"), atom.create("parallel_emit")]
  let key = atom.create("worker_id")
  let worker_field =
    fields.field(key, fn(id: Int) { Ok(dynamic.int(id)) }, fn(dyn) {
      case decode.run(dyn, decode.int) {
        Ok(n) -> Ok(n)
        Error(_) -> Error(fields.FieldDecodeError("expected int"))
      }
    })
  let assert Ok(ev) = sinal.event(ev_name, worker_field, fields.empty())
  let assert Ok(hid) = sinal.handler_id("concurrency-parallel-handler")
  let subject = process.new_subject()

  let handler =
    sinal.handler(fn(_ev, worker_id: Int, _meta) {
      process.send(subject, worker_id)
      Ok(Nil)
    })
  let assert Ok(att) = sinal.attach(hid, ev, handler, fn(_, _) { Nil })

  // Spawn 5 workers that emit concurrently
  process.spawn(fn() { sinal.emit(ev, 1, Nil) })
  process.spawn(fn() { sinal.emit(ev, 2, Nil) })
  process.spawn(fn() { sinal.emit(ev, 3, Nil) })
  process.spawn(fn() { sinal.emit(ev, 4, Nil) })
  process.spawn(fn() { sinal.emit(ev, 5, Nil) })

  // Receive all 5 events
  let assert Ok(_) = process.receive(subject, 200)
  let assert Ok(_) = process.receive(subject, 200)
  let assert Ok(_) = process.receive(subject, 200)
  let assert Ok(_) = process.receive(subject, 200)
  let assert Ok(_) = process.receive(subject, 200)

  sinal.detach(att) |> should.equal(Ok(Nil))
}

pub fn telemetry_persist_preserves_handlers_test() {
  let ev_name = [atom.create("persist_test"), atom.create("lifecycle")]
  let empty = fields.empty()
  let assert Ok(ev) = sinal.event(ev_name, empty, empty)
  let assert Ok(hid1) = sinal.handler_id("persist-handler-1")
  let subject1 = process.new_subject()
  let subject2 = process.new_subject()

  let handler1 =
    sinal.handler(fn(_ev, _meas, _meta) {
      process.send(subject1, "h1")
      Ok(Nil)
    })
  let assert Ok(att1) = sinal.attach(hid1, ev, handler1, fn(_, _) { Nil })

  // Emit before persist
  sinal.emit(ev, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(subject1, 100) |> should.equal(Ok("h1"))

  // Persist handlers (moves ETS to persistent_term)
  telemetry_persist()

  // Emit after persist still reaches handler1
  sinal.emit(ev, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(subject1, 100) |> should.equal(Ok("h1"))

  // Attach new handler after persist
  let assert Ok(hid2) = sinal.handler_id("persist-handler-2")
  let handler2 =
    sinal.handler(fn(_ev, _meas, _meta) {
      process.send(subject2, "h2")
      Ok(Nil)
    })
  let assert Ok(att2) = sinal.attach(hid2, ev, handler2, fn(_, _) { Nil })

  sinal.emit(ev, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(subject1, 100) |> should.equal(Ok("h1"))
  process.receive(subject2, 100) |> should.equal(Ok("h2"))

  sinal.detach(att1) |> should.equal(Ok(Nil))
  sinal.detach(att2) |> should.equal(Ok(Nil))
}

pub fn detach_in_flight_barrier_race_test() {
  let ev_name = [atom.create("detach_race"), atom.create("in_flight")]
  let empty = fields.empty()
  let assert Ok(ev) = sinal.event(ev_name, empty, empty)
  let assert Ok(hid) = sinal.handler_id("in-flight-race-handler")

  let in_flight_started_subject = process.new_subject()
  let finished_subject = process.new_subject()

  let handler =
    sinal.handler(fn(_ev, _meas, _meta) {
      // The executing process creates its own subject so it can receive from the coordinator
      let allow_finish_subject = process.new_subject()
      process.send(in_flight_started_subject, allow_finish_subject)
      // Block until coordinator confirms detach has executed
      let assert Ok(Nil) = process.receive(allow_finish_subject, 2000)
      process.send(finished_subject, "callback_finished")
      Ok(Nil)
    })
  let assert Ok(att) = sinal.attach(hid, ev, handler, fn(_, _) { Nil })

  // Spawn emitter process that calls emit synchronously
  process.spawn(fn() {
    let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
    Nil
  })

  // Coordinator waits until the callback is actively executing inside the emitter process
  let assert Ok(allow_finish_subject) =
    process.receive(in_flight_started_subject, 1000)

  // While callback is in flight, coordinator detaches the handler
  sinal.detach(att) |> should.equal(Ok(Nil))

  // Permit the in-flight callback to finish
  process.send(allow_finish_subject, Nil)

  // In-flight callback finishes its execution cleanly
  process.receive(finished_subject, 1000)
  |> should.equal(Ok("callback_finished"))

  // Subsequent emissions from any process do NOT invoke the detached handler
  sinal.emit(ev, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(in_flight_started_subject, 50) |> should.be_error()

  // Repeated detach reports NotAttached
  sinal.detach(att) |> should.equal(Error(sinal.NotAttached))
}

pub fn overlapping_subscriptions_order_independent_test() {
  let ev1_name = [atom.create("overlap"), atom.create("ev1")]
  let ev2_name = [atom.create("overlap"), atom.create("ev2")]
  let empty = fields.empty()
  let assert Ok(ev1) = sinal.event(ev1_name, empty, empty)
  let assert Ok(ev2) = sinal.event(ev2_name, empty, empty)

  let delivery_subject = process.new_subject()

  let assert Ok(hid1) = sinal.handler_id("overlap-handler-1")
  let assert Ok(hid2) = sinal.handler_id("overlap-handler-2")

  let handler1 =
    sinal.handler(fn(ev, _, _) {
      process.send(delivery_subject, #("handler_1", sinal.event_name(ev)))
      Ok(Nil)
    })
  let handler2 =
    sinal.handler(fn(ev, _, _) {
      process.send(delivery_subject, #("handler_2", sinal.event_name(ev)))
      Ok(Nil)
    })

  // Handler 1 listens only to ev1
  let assert Ok(att1) = sinal.attach(hid1, ev1, handler1, fn(_, _) { Nil })
  // Handler 2 listens to both ev1 and ev2 via attach_many
  let assert Ok(att2) =
    sinal.attach_many(hid2, ev1, [ev2], handler2, fn(_, _) { Nil })

  // Emit ev1: BOTH handlers are invoked.
  // Order between handlers is unspecified in BEAM telemetry; assert order-independently.
  let assert Ok(Nil) = sinal.emit(ev1, Nil, Nil)

  let assert Ok(msg_a) = process.receive(delivery_subject, 100)
  let assert Ok(msg_b) = process.receive(delivery_subject, 100)
  let received_ev1 = [msg_a, msg_b]
  list.contains(received_ev1, #("handler_1", ["overlap", "ev1"]))
  |> should.equal(True)
  list.contains(received_ev1, #("handler_2", ["overlap", "ev1"]))
  |> should.equal(True)

  // Emit ev2: ONLY handler 2 is invoked
  let assert Ok(Nil) = sinal.emit(ev2, Nil, Nil)
  let assert Ok(msg_c) = process.receive(delivery_subject, 100)
  msg_c |> should.equal(#("handler_2", ["overlap", "ev2"]))
  process.receive(delivery_subject, 50) |> should.be_error()

  sinal.detach(att1) |> should.equal(Ok(Nil))
  sinal.detach(att2) |> should.equal(Ok(Nil))
}

pub fn public_id_replacement_after_detach_test() {
  let ev_name = [atom.create("replace"), atom.create("event")]
  let empty = fields.empty()
  let assert Ok(ev) = sinal.event(ev_name, empty, empty)
  let assert Ok(hid) = sinal.handler_id("reusable-handler-id")
  let subject = process.new_subject()

  let handler_v1 =
    sinal.handler(fn(_, _, _) {
      process.send(subject, "v1")
      Ok(Nil)
    })
  let handler_v2 =
    sinal.handler(fn(_, _, _) {
      process.send(subject, "v2")
      Ok(Nil)
    })

  let assert Ok(att1) = sinal.attach(hid, ev, handler_v1, fn(_, _) { Nil })
  // Duplicate attach fails while attached
  sinal.attach(hid, ev, handler_v2, fn(_, _) { Nil })
  |> should.equal(Error(sinal.AlreadyExists))

  // Emit invokes v1
  let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
  process.receive(subject, 100) |> should.equal(Ok("v1"))

  // Detach att1
  sinal.detach(att1) |> should.equal(Ok(Nil))

  // Now attaching with same hid succeeds
  let assert Ok(att2) = sinal.attach(hid, ev, handler_v2, fn(_, _) { Nil })
  let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
  process.receive(subject, 100) |> should.equal(Ok("v2"))

  sinal.detach(att2) |> should.equal(Ok(Nil))
}

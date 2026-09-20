import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
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
  let listener_cb = fn(_, _, _, _) {
    process.send(telemetry_failure_subject, Nil)
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

  // Upstream failure event occurred
  process.receive(telemetry_failure_subject, 100) |> should.be_ok()
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
  let listener_cb = fn(_, _, _, _) {
    process.send(telemetry_failure_subject, Nil)
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

  process.receive(telemetry_failure_subject, 100) |> should.be_ok()
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
  let listener_cb = fn(_, _, _, _) {
    process.send(telemetry_failure_subject, Nil)
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

  process.receive(telemetry_failure_subject, 100) |> should.be_ok()
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
  let listener_cb = fn(_, _, _, _) {
    process.send(telemetry_failure_subject, Nil)
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

  // Upstream failure event fired
  process.receive(telemetry_failure_subject, 100) |> should.be_ok()
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

@external(erlang, "scope_test_ffi", "catch_exception")
fn catch_exception(fun: fn() -> a) -> Dynamic

@external(erlang, "scope_test_ffi", "raise_test_error")
fn raise_test_error(reason: String) -> a

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
  let subject = process.new_subject()
  let handler =
    sinal.handler(fn(_, _, _) {
      process.send(subject, "called_before_crash")
      Ok(Nil)
    })

  let caught =
    catch_exception(fn() {
      sinal.with_attachments(
        ev,
        [],
        handler,
        fn(_, _) { Nil },
        fn(_) { Nil },
        fn() {
          let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
          raise_test_error("work_failure_error")
        },
      )
    })

  // Verify exception was caught and re-raised with the original reason
  case decode.run(caught, decode.dynamic) {
    Ok(_) -> Nil
    Error(_) -> panic as "expected caught exception"
  }
  process.receive(subject, 100) |> should.equal(Ok("called_before_crash"))

  // Handler was cleaned up despite work exception
  let assert Ok(Nil) = sinal.emit(ev, Nil, Nil)
  process.receive(subject, 50) |> should.be_error()
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
          // Original work raises exception
          raise_test_error("original_work_error")
        },
      )
    })

  // Cleanup failure was reported to on_cleanup_failure
  let assert Ok(failure) = process.receive(cleanup_failure_subject, 100)
  failure
  |> should.equal(sinal.DetachReturnedError(sinal.NotAttached))

  // Work exception was still re-raised despite reporter panic
  case decode.run(caught, decode.dynamic) {
    Ok(_) -> Nil
    Error(_) -> panic as "expected caught exception"
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

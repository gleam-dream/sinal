import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import gleeunit
import gleeunit/should
import sinal
import sinal/fields
import sinal/internal/ffi
import sinal/span

pub fn main() -> Nil {
  gleeunit.main()
}

pub fn primitive_fields_round_trip_and_reject_malformed_native_values_test() {
  let string_key = "ergonomic_string"
  let int_key = "ergonomic_int"
  let bool_key = "ergonomic_bool"

  let string_field = fields.string(string_key)
  let int_field = fields.int(int_key)
  let bool_field = fields.bool(bool_key)

  let string_map = fields.encode(string_field, "hello")
  let int_map = fields.encode(int_field, 42)
  let bool_map = fields.encode(bool_field, True)

  fields.decode(string_field, string_map) |> should.equal(Ok("hello"))
  fields.decode(int_field, int_map) |> should.equal(Ok(42))
  fields.decode(bool_field, bool_map) |> should.equal(Ok(True))

  fields.decode(string_field, native_map([#(string_key, dynamic.int(7))]))
  |> should.be_error()
  fields.decode(int_field, native_map([#(int_key, dynamic.string("7"))]))
  |> should.be_error()
  fields.decode(bool_field, native_map([#(bool_key, dynamic.int(1))]))
  |> should.be_error()
  fields.decode(int_field, native_map([]))
  |> should.equal(Error(fields.MissingField("ergonomic_int")))
}

pub fn observe_runs_synchronously_and_detaches_test() {
  let ev =
    sinal.event(
      ["test", "observe_simple"],
      fields.int("count"),
      fields.string("name"),
    )
  let caller = process.self()
  let subject = process.new_subject()
  let attachment =
    sinal.observe(ev, fn(count, name) {
      process.send(subject, #(count, name, process.self()))
    })

  sinal.emit(ev, 3, "Ada")
  process.receive(subject, 100) |> should.equal(Ok(#(3, "Ada", caller)))

  sinal.detach(attachment) |> should.equal(Ok(Nil))
  sinal.emit(ev, 4, "Lin")
  process.receive(subject, 50) |> should.be_error()
}

pub fn observe_malformed_native_map_skips_one_invocation_test() {
  let key = "count"
  let ev_name = ["test", "observe_malformed"]
  let ev = sinal.event(ev_name, fields.int(key), fields.empty())
  let subject = process.new_subject()
  let attachment =
    sinal.observe(ev, fn(_count, _metadata) { process.send(subject, Nil) })

  let failure_event = telemetry_failure_event()
  let listener_id =
    ffi.to_dynamic(atom.create("observe_malformed_failure_listener"))
  let failure_subject = process.new_subject()
  let listener = fn(_, measurements, metadata) {
    process.send(failure_subject, decode_failure_event(measurements, metadata))
  }
  let assert Ok(Nil) =
    ffi.telemetry_attach_many(listener_id, [failure_event], listener)

  native_emit(
    ev_name,
    native_map([#(key, dynamic.string("bad"))]),
    native_map([]),
  )
  process.receive(subject, 50) |> should.be_error()
  // The skipped invocation is not a handler failure to telemetry.
  process.receive(failure_subject, 50) |> should.be_error()
  native_emit(ev_name, native_map([#(key, dynamic.int(1))]), native_map([]))
  process.receive(subject, 100) |> should.equal(Ok(Nil))
  let _ = ffi.telemetry_detach(listener_id)
  sinal.detach(attachment) |> should.equal(Ok(Nil))
}

pub fn observe_callback_panic_keeps_native_failure_isolation_test() {
  let ev_name = ["test", "observe_panic"]
  let ev = sinal.event(ev_name, fields.empty(), fields.empty())
  let attachment = sinal.observe(ev, fn(_, _) { panic as "observer panic" })

  let failure_event = telemetry_failure_event()
  let listener_id =
    ffi.to_dynamic(atom.create("observe_panic_failure_listener"))
  let failure_subject = process.new_subject()
  let listener = fn(_, measurements, metadata) {
    process.send(failure_subject, decode_failure_event(measurements, metadata))
  }
  let assert Ok(Nil) =
    ffi.telemetry_attach_many(listener_id, [failure_event], listener)

  sinal.emit(ev, Nil, Nil)
  let assert Ok(failure) = process.receive(failure_subject, 100)
  failure.event_name |> should.equal(["test", "observe_panic"])
  is_panic_reason(failure.reason, "observer panic") |> should.equal(True)
  failure.has_stacktrace |> should.equal(True)
  let _ = ffi.telemetry_detach(listener_id)
  sinal.detach(attachment) |> should.equal(Error(Nil))
}

pub fn with_id_rejects_an_empty_id_test() {
  let ev = sinal.event(["test", "empty_id"], fields.empty(), fields.empty())
  panic_message(fn() {
    sinal.subscription(ev, fn(_, _) { Nil }) |> sinal.with_id("")
  })
  |> should.equal(Ok("sinal.with_id: the handler id is empty"))
}

pub fn event_name_definition_bugs_panic_with_the_name_test() {
  let empty = fields.empty()
  panic_message(fn() { sinal.event([], empty, empty) })
  |> should.equal(Ok("sinal.event: the event name is empty"))
  panic_message(fn() { sinal.event(["http", "Request"], empty, empty) })
  |> should.equal(Ok(
    "sinal.event: invalid name segment \"Request\"; it must match [a-z][a-z0-9_]{0,62}. Names and keys become atoms, so write them in source code and never build them from input.",
  ))
  let assert Ok(_) =
    panic_message(fn() { sinal.event(["user@example.com"], empty, empty) })
  let assert Ok(_) =
    panic_message(fn() { sinal.event(["9lives"], empty, empty) })
  let assert Ok(_) =
    panic_message(fn() { sinal.event([string.repeat("a", 64)], empty, empty) })

  let ev = sinal.event(["valid_event", "a1_b2"], empty, empty)
  sinal.name(ev) |> should.equal(["valid_event", "a1_b2"])
  sinal.name(sinal.event([string.repeat("a", 63)], empty, empty))
  |> should.equal([string.repeat("a", 63)])
}

pub fn span_name_definition_bugs_panic_test() {
  let empty = fields.empty()
  panic_message(fn() {
    span.define(
      [],
      start_metadata: empty,
      stop_measurements: empty,
      stop_metadata: empty,
    )
  })
  |> should.equal(Ok("sinal/span.define: the span name is empty"))
  let assert Ok(_) =
    panic_message(fn() {
      span.define(
        ["Http"],
        start_metadata: empty,
        stop_measurements: empty,
        stop_metadata: empty,
      )
    })
}

pub fn record_builder_round_trips_and_rejects_a_duplicate_key_test() {
  let codec = {
    use a <- fields.include(fields.int("field_a"), get: fn(p) { p.0 })
    use b <- fields.include(fields.string("field_b"), get: fn(p) { p.1 })
    fields.success(#(a, b))
  }
  fields.keys(codec) |> should.equal(["field_a", "field_b"])
  let raw = fields.encode(codec, #(1, "one"))
  raw
  |> should.equal(
    native_map([
      #("field_a", dynamic.int(1)),
      #("field_b", dynamic.string("one")),
    ]),
  )
  fields.decode(codec, raw) |> should.equal(Ok(#(1, "one")))
  fields.decode(codec, native_map([#("field_a", dynamic.int(1))]))
  |> should.equal(Error(fields.MissingField("field_b")))
  fields.decode(codec, dynamic.int(3)) |> should.equal(Error(fields.NotAMap))

  let twice = fn() {
    use a <- fields.include(fields.int("field_a"), get: fn(p) { p.0 })
    use b <- fields.include(fields.int("field_a"), get: fn(p) { p.1 })
    fields.success(#(a, b))
  }
  let message =
    Ok("sinal/fields.include: key \"field_a\" is declared twice in one record")
  panic_message(twice) |> should.equal(message)
  // A nested record's keys count as the outer record's keys.
  panic_message(fn() {
    use a <- fields.include(fields.int("field_a"), get: fn(p) { p.0 })
    use b <- fields.include(fields.int("field_b"), get: fn(p) { p.1 })
    use c <- fields.include(
      {
        use c <- fields.include(fields.int("field_c"), get: fn(p) { p })
        use _ <- fields.include(fields.int("field_a"), get: fn(p) { p })
        fields.success(c)
      },
      get: fn(p) { p.2 },
    )
    fields.success(#(a, b, c))
  })
  |> should.equal(message)
}

// A decode marks the process while it runs a record's block again, so the
// records built there skip their encoding plans. The mark must not outlive
// a decoder that raises: a record defined afterwards still checks its keys.
pub fn a_raising_decoder_does_not_leave_the_process_decoding_test() {
  let fragile =
    fields.field(
      "attempt",
      dynamic.int,
      decode.int
        |> decode.then(fn(n) {
          case n {
            13 -> panic as "unlucky"
            _ -> decode.success(n)
          }
        }),
    )
  let codec = {
    use attempt <- fields.include(fragile, get: fn(p) { p.0 })
    use route <- fields.include(fields.string("route"), get: fn(p) { p.1 })
    fields.success(#(attempt, route))
  }
  let raw =
    native_map([#("attempt", dynamic.int(13)), #("route", dynamic.string("/"))])
  panic_message(fn() { fields.decode(codec, raw) })
  |> should.equal(Ok("unlucky"))
  panic_message(fn() {
    use a <- fields.include(fields.int("twice"), get: fn(p) { p.0 })
    use b <- fields.include(fields.int("twice"), get: fn(p) { p.1 })
    fields.success(#(a, b))
  })
  |> should.equal(Ok(
    "sinal/fields.include: key \"twice\" is declared twice in one record",
  ))
  fields.decode(
    codec,
    native_map([#("attempt", dynamic.int(1)), #("route", dynamic.string("/"))]),
  )
  |> should.equal(Ok(#(1, "/")))
}

pub type Window {
  Window(start: Int, end: Int)
}

// Regression: the old builder bound fields to constructor parameters by
// position, so these two Int fields, listed in the other order than the
// constructor's, decoded `start` as `end` and back. `include` binds each by
// name.
pub fn record_fields_of_one_type_bind_by_name_in_any_order_test() {
  let window = {
    use end <- fields.include(fields.int("end"), get: fn(w) { w.end })
    use start <- fields.include(fields.int("start"), get: fn(w) { w.start })
    fields.success(Window(start:, end:))
  }
  fields.keys(window) |> should.equal(["end", "start"])
  fields.encode(window, Window(start: 1, end: 2))
  |> should.equal(
    native_map([#("start", dynamic.int(1)), #("end", dynamic.int(2))]),
  )
  fields.decode(
    window,
    native_map([#("start", dynamic.int(1)), #("end", dynamic.int(2))]),
  )
  |> should.equal(Ok(Window(start: 1, end: 2)))
  fields.decode(window, fields.encode(window, Window(start: 3, end: 4)))
  |> should.equal(Ok(Window(start: 3, end: 4)))
}

pub type Delivery {
  Delivery(
    route: String,
    status: Int,
    method: Method,
    retried: Bool,
    ratio: Float,
    note: Option(String),
  )
}

// Every getter here is unannotated: the rest of each `use` block, which
// ends in `success`, fixes the record type before the getter is checked.
fn delivery_fields() -> fields.Fields(Delivery) {
  use route <- fields.include(fields.string("route"), get: fn(d) { d.route })
  use status <- fields.include(fields.int("status"), get: fn(d) { d.status })
  use method <- fields.include(method_field(), get: fn(d) { d.method })
  use retried <- fields.include(fields.bool("retried"), get: fn(d) { d.retried })
  use ratio <- fields.include(fields.float("ratio"), get: fn(d) { d.ratio })
  use note <- fields.include(fields.optional(fields.string("note")), get: fn(d) {
    d.note
  })
  fields.success(Delivery(route:, status:, method:, retried:, ratio:, note:))
}

fn method_field() -> fields.Fields(Method) {
  fields.enum("method", [Get, Post], fn(m) {
    case m {
      Get -> "get"
      Post -> "post"
    }
  })
}

pub fn annotation_free_multi_field_record_round_trips_test() {
  let codec = delivery_fields()
  fields.keys(codec)
  |> should.equal(["route", "status", "method", "retried", "ratio", "note"])
  let delivery =
    Delivery(
      route: "/users",
      status: 200,
      method: Post,
      retried: False,
      ratio: 0.5,
      note: None,
    )
  let raw = fields.encode(codec, delivery)
  raw
  |> should.equal(
    native_map([
      #("route", dynamic.string("/users")),
      #("status", dynamic.int(200)),
      #("method", dynamic.string("post")),
      #("retried", dynamic.bool(False)),
      #("ratio", dynamic.float(0.5)),
    ]),
  )
  fields.decode(codec, raw) |> should.equal(Ok(delivery))
  let noted = Delivery(..delivery, note: Some("slow"))
  fields.decode(codec, fields.encode(codec, noted)) |> should.equal(Ok(noted))
  // The first field that fails, in declaration order, is reported.
  fields.decode(codec, native_map([#("status", dynamic.int(200))]))
  |> should.equal(Error(fields.MissingField("route")))
}

pub fn event_codecs_pin_the_native_maps_without_a_handler_test() {
  let event =
    sinal.event(
      ["sinal_test", "delivery"],
      fields.int("duration_ms"),
      delivery_fields(),
    )
  fields.encode(sinal.measurement_fields(event), 42)
  |> should.equal(native_map([#("duration_ms", dynamic.int(42))]))
  let delivery =
    Delivery(
      route: "/users",
      status: 201,
      method: Get,
      retried: True,
      ratio: 1.0,
      note: Some("first"),
    )
  fields.encode(sinal.metadata_fields(event), delivery)
  |> should.equal(
    native_map([
      #("route", dynamic.string("/users")),
      #("status", dynamic.int(201)),
      #("method", dynamic.string("get")),
      #("retried", dynamic.bool(True)),
      #("ratio", dynamic.float(1.0)),
      #("note", dynamic.string("first")),
    ]),
  )
  fields.keys(sinal.metadata_fields(event))
  |> should.equal(["route", "status", "method", "retried", "ratio", "note"])

  // The same map reaches a native handler of the event.
  let seen = process.new_subject()
  let attachment =
    sinal.observe(
      sinal.event(
        ["sinal_test", "delivery"],
        fields.field("duration_ms", dynamic.int, decode.int),
        fields.field("route", dynamic.string, decode.string),
      ),
      fn(duration, route) { process.send(seen, #(duration, route)) },
    )
  sinal.emit(event, 42, delivery)
  process.receive(seen, 100) |> should.equal(Ok(#(42, "/users")))
  sinal.detach(attachment) |> should.equal(Ok(Nil))
}

pub fn success_alone_declares_no_keys_test() {
  let codec = fields.success(Get)
  fields.keys(codec) |> should.equal([])
  fields.encode(codec, Post) |> should.equal(native_map([]))
  fields.decode(codec, native_map([#("other", dynamic.int(1))]))
  |> should.equal(Ok(Get))
  fields.decode(codec, dynamic.int(1)) |> should.equal(Error(fields.NotAMap))
}

pub fn field_keeps_the_decoder_errors_test() {
  let field = fields.field("attempt", dynamic.int, decode.int)
  fields.encode(field, 10)
  |> should.equal(native_map([#("attempt", dynamic.int(10))]))
  let assert Error(fields.InvalidField("attempt", [error])) =
    fields.decode(field, native_map([#("attempt", dynamic.string("x"))]))
  error.expected |> should.equal("Int")
  fields.describe_error(fields.InvalidField("attempt", [error]))
  |> should.equal("invalid value at key attempt: expected Int, found String")
  fields.describe_error(fields.MissingField("attempt"))
  |> should.equal("missing key attempt")
  fields.describe_error(fields.NotAMap) |> should.equal("expected a native map")
}

pub fn float_and_enum_fields_round_trip_test() {
  let ratio = fields.float("ratio")
  fields.decode(ratio, fields.encode(ratio, 0.5)) |> should.equal(Ok(0.5))
  // A native producer may send a whole-number measurement as an integer.
  fields.decode(ratio, native_map([#("ratio", dynamic.int(2))]))
  |> should.equal(Ok(2.0))

  let method =
    fields.enum("method", [Get, Post], fn(m) {
      case m {
        Get -> "get"
        Post -> "post"
      }
    })
  fields.encode(method, Post)
  |> should.equal(native_map([#("method", dynamic.string("post"))]))
  fields.decode(method, native_map([#("method", dynamic.string("get"))]))
  |> should.equal(Ok(Get))
  // An Elixir producer may send the name as an atom.
  fields.decode(
    method,
    native_map([#("method", ffi.to_dynamic(atom.create("post")))]),
  )
  |> should.equal(Ok(Post))
  let assert Error(fields.InvalidField("method", [error])) =
    fields.decode(method, native_map([#("method", dynamic.string("put"))]))
  error.expected |> should.equal("one of get, post")
}

pub fn enum_definition_bugs_panic_test() {
  panic_message(fn() { fields.enum("method", [], fn(_: Method) { "x" }) })
  |> should.equal(Ok("sinal/fields.enum: key \"method\" has no values"))
  panic_message(fn() { fields.enum("method", [Get, Post], fn(_) { "same" }) })
  |> should.equal(Ok(
    "sinal/fields.enum: key \"method\" gives two values the name \"same\"",
  ))
}

pub fn field_key_definition_bugs_panic_test() {
  panic_message(fn() { fields.int("Duration") })
  |> should.equal(Ok(
    "sinal/fields.int: invalid key \"Duration\"; it must match [a-z][a-z0-9_]{0,62}. Names and keys become atoms, so write them in source code and never build them from input.",
  ))
  let assert Ok(_) = panic_message(fn() { fields.string("") })
  let assert Ok(_) = panic_message(fn() { fields.bool("a-b") })
  let assert Ok(_) = panic_message(fn() { fields.float("tenant_ü") })
  let assert Ok(_) =
    panic_message(fn() { fields.field("x y", dynamic.int, decode.int) })
}

pub fn empty_fields_rejects_non_map_boundary_test() {
  let empty = fields.empty()
  fields.decode(empty, native_map([])) |> should.equal(Ok(Nil))
  fields.decode(empty, dynamic.int(42)) |> should.equal(Error(fields.NotAMap))
  fields.decode(empty, dynamic.string("not_a_map"))
  |> should.equal(Error(fields.NotAMap))
  fields.decode(fields.int("n"), dynamic.int(42))
  |> should.equal(Error(fields.NotAMap))
}

pub fn optional_field_round_trips_and_treats_absence_as_none_test() {
  let key = "nickname"
  let optional_string = fields.optional(fields.string(key))

  // Some encodes and decodes through the inner field.
  let present_map = fields.encode(optional_string, Some("Ada"))
  fields.decode(optional_string, present_map) |> should.equal(Ok(Some("Ada")))

  // None encodes by omitting the key entirely, producing an empty map.
  let absent_map = fields.encode(optional_string, None)
  absent_map |> should.equal(native_map([]))
  fields.decode(optional_string, native_map([])) |> should.equal(Ok(None))
  fields.decode(optional_string, absent_map) |> should.equal(Ok(None))

  // A present, non-marker value decodes through `inner` even when it is
  // itself falsy-looking (an empty string), proving decoding is driven by
  // the marker check, not by the decoded value.
  fields.decode(optional_string, native_map([#(key, dynamic.string(""))]))
  |> should.equal(Ok(Some("")))

  // A raw `nil` or `undefined` marker at the key is also None, not a decode
  // failure, matching a foreign producer that writes an explicit marker
  // instead of omitting the key.
  fields.decode(
    optional_string,
    native_map([#(key, ffi.to_dynamic(atom.create("nil")))]),
  )
  |> should.equal(Ok(None))
  fields.decode(
    optional_string,
    native_map([#(key, ffi.to_dynamic(atom.create("undefined")))]),
  )
  |> should.equal(Ok(None))

  // A present, non-marker value that fails the inner decode still fails.
  fields.decode(optional_string, native_map([#(key, dynamic.int(1))]))
  |> should.be_error()
}

pub fn optional_rejects_inner_with_other_than_one_key_test() {
  panic_message(fn() { fields.optional(fields.empty()) })
  |> should.equal(Ok(
    "sinal/fields.optional: the inner field must declare exactly one key, got []",
  ))
  let two_keys = {
    use a <- fields.include(fields.int("a"), get: fn(p) { p.0 })
    use b <- fields.include(fields.int("b"), get: fn(p) { p.1 })
    fields.success(#(a, b))
  }
  panic_message(fn() { fields.optional(two_keys) })
  |> should.equal(Ok(
    "sinal/fields.optional: the inner field must declare exactly one key, got [\"a\", \"b\"]",
  ))
}

pub fn handler_rejects_no_events_and_a_repeated_event_test() {
  let empty = fields.empty()
  let ev_a1 = sinal.event(["event_a"], empty, empty)
  let ev_a2 = sinal.event(["event_a"], empty, empty)
  let ev_b = sinal.event(["event_b"], empty, empty)
  let run = fn(_, _, _) { Ok(Nil) }
  let on_failure = fn(_, _: sinal.HandlerFailure(Nil)) { Nil }

  // Disjoint event names succeed
  let assert Ok(attachment) =
    sinal.attach(sinal.handler([ev_a1, ev_b], run, on_failure))
  sinal.detach(attachment) |> should.equal(Ok(Nil))

  panic_message(fn() { sinal.handler([ev_a1, ev_a2], run, on_failure) })
  |> should.equal(Ok("sinal.handler: event [\"event_a\"] is listed twice"))
  panic_message(fn() { sinal.handler([], run, on_failure) })
  |> should.equal(Ok("sinal.handler: no events"))
}

pub fn span_reserved_field_rejection_test() {
  let empty = fields.empty()
  panic_message(fn() {
    span.define(
      ["test_prefix"],
      start_metadata: empty,
      stop_measurements: fields.int("duration"),
      stop_metadata: empty,
    )
  })
  |> should.equal(Ok(
    "sinal/span.define: stop measurement key \"duration\" is reserved by the span protocol",
  ))
  panic_message(fn() {
    span.define(
      ["test_prefix"],
      start_metadata: fields.string("telemetry_span_context"),
      stop_measurements: empty,
      stop_metadata: empty,
    )
  })
  |> should.equal(Ok(
    "sinal/span.define: start metadata key \"telemetry_span_context\" is reserved by the span protocol",
  ))
  panic_message(fn() {
    span.define(
      ["test_prefix"],
      start_metadata: fields.string("kind"),
      stop_measurements: empty,
      stop_metadata: empty,
    )
  })
  |> should.equal(Ok(
    "sinal/span.define: start metadata key \"kind\" is reserved by the span protocol",
  ))
  panic_message(fn() {
    span.define(
      ["test_prefix"],
      start_metadata: empty,
      stop_measurements: empty,
      stop_metadata: fields.string("telemetry_span_context"),
    )
  })
  |> should.equal(Ok(
    "sinal/span.define: stop metadata key \"telemetry_span_context\" is reserved by the span protocol",
  ))
}

pub fn native_attach_and_emit_synchronous_delivery_test() {
  let key_count = "delivery_count"
  let key_user = "delivery_user"
  let field_count = fields.field(key_count, dynamic.int, decode.int)
  let field_user = fields.field(key_user, dynamic.string, decode.string)
  let ev = sinal.event(["test", "sync", "delivery"], field_count, field_user)
  let hid = "sync-delivery-handler"
  let parent = process.self()
  let subject = process.new_subject()
  let handler = fn(selected_ev, count: Int, user: String) {
    let calling_pid = process.self()
    process.send(subject, #(sinal.name(selected_ev), count, user, calling_pid))
    Ok(Nil)
  }
  let assert Ok(att) =
    sinal.attach(
      sinal.handler([ev], handler, fn(_, _) { Nil }) |> sinal.with_id(hid),
    )
  sinal.emit(ev, 100, "bob")
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
  let ev = sinal.event(["test", "dup_id"], empty, empty)
  let hid = "duplicate-id-test"
  let handler = fn(_, _, _) { Ok(Nil) }
  let assert Ok(att) =
    sinal.attach(
      sinal.handler([ev], handler, fn(_, _) { Nil }) |> sinal.with_id(hid),
    )
  sinal.attach(
    sinal.handler([ev], handler, fn(_, _) { Nil }) |> sinal.with_id(hid),
  )
  |> should.equal(Error(sinal.AlreadyExists(hid)))
  sinal.detach(att) |> should.equal(Ok(Nil))
}

pub fn detach_and_repeated_detach_test() {
  let empty = fields.empty()
  let ev = sinal.event(["test", "repeated_detach"], empty, empty)
  let hid = "repeated-detach-test"
  let subject = process.new_subject()
  let handler = fn(_, _, _) {
    process.send(subject, Nil)
    Ok(Nil)
  }
  let assert Ok(att) =
    sinal.attach(
      sinal.handler([ev], handler, fn(_, _) { Nil }) |> sinal.with_id(hid),
    )
  sinal.detach(att) |> should.equal(Ok(Nil))
  sinal.detach(att) |> should.equal(Error(Nil))
  // After detach, emitting should not invoke the handler
  sinal.emit(ev, Nil, Nil)
  process.receive(subject, 50) |> should.be_error()
}

pub fn attach_many_multi_event_descriptor_selection_test() {
  let empty = fields.empty()
  let ev_a = sinal.event(["test", "multi", "a"], empty, empty)
  let ev_b = sinal.event(["test", "multi", "b"], empty, empty)
  let hid = "attach-many-selection-test"
  let subject = process.new_subject()
  let handler = fn(selected_ev, _, _) {
    process.send(subject, sinal.name(selected_ev))
    Ok(Nil)
  }
  let assert Ok(att) =
    sinal.attach(
      sinal.handler([ev_a, ev_b], handler, fn(_, _) { Nil })
      |> sinal.with_id(hid),
    )
  sinal.emit(ev_a, Nil, Nil)
  process.receive(subject, 100)
  |> should.equal(Ok(["test", "multi", "a"]))
  sinal.emit(ev_b, Nil, Nil)
  process.receive(subject, 100)
  |> should.equal(Ok(["test", "multi", "b"]))
  sinal.detach(att) |> should.equal(Ok(Nil))
}

pub fn emitted_maps_carry_exactly_the_encoded_keys_test() {
  let ev =
    sinal.event(
      ["test", "encoded_keys"],
      fields.int("count"),
      fields.optional(fields.string("nickname")),
    )
  let raw = process.new_subject()
  let listener_id = ffi.to_dynamic(atom.create("encoded_keys_listener"))
  let assert Ok(Nil) =
    ffi.telemetry_attach_many(
      listener_id,
      [[atom.create("test"), atom.create("encoded_keys")]],
      fn(_, measurements, metadata) {
        process.send(raw, #(measurements, metadata))
      },
    )
  sinal.emit(ev, 3, None)
  process.receive(raw, 100)
  |> should.equal(
    Ok(#(native_map([#("count", dynamic.int(3))]), native_map([]))),
  )
  let _ = ffi.telemetry_detach(listener_id)
}

pub fn malformed_measurements_invokes_failure_observer_and_keeps_handler_test() {
  let key = "int_field"
  let int_field = fields.field(key, dynamic.int, decode.int)
  let ev_name = ["test", "malformed_meas"]
  let ev = sinal.event(ev_name, int_field, fields.empty())
  let hid = "malformed-meas-handler"
  let failure_subject = process.new_subject()
  let on_failure = fn(selected_ev, failure) {
    process.send(failure_subject, #(sinal.name(selected_ev), failure))
  }
  let runs = process.new_subject()
  let handler = fn(_, _, _) {
    process.send(runs, Nil)
    Ok(Nil)
  }
  let assert Ok(att) =
    sinal.attach(sinal.handler([ev], handler, on_failure) |> sinal.with_id(hid))

  // Listen for native telemetry [telemetry, handler, failure]
  let failure_event = telemetry_failure_event()
  let listener_id =
    ffi.to_dynamic(atom.create("telemetry_failure_listener_meas"))
  let telemetry_failure_subject = process.new_subject()
  let listener_cb = fn(ev_name, measurements, metadata) {
    let rec = decode_failure_event(measurements, metadata)
    process.send(telemetry_failure_subject, #(ev_name, rec))
  }
  let assert Ok(Nil) =
    ffi.telemetry_attach_many(listener_id, [failure_event], listener_cb)

  // Emit raw foreign event with bad measurement (string instead of int)
  let bad_measurements = native_map([#(key, dynamic.string("not_an_int"))])
  native_emit(ev_name, bad_measurements, native_map([]))

  // on_failure called with MalformedMeasurements
  let assert Ok(#(ev_label, failure)) = process.receive(failure_subject, 100)
  ev_label |> should.equal(["test", "malformed_meas"])
  case failure {
    sinal.MalformedMeasurements(_) -> Nil
    _ -> panic as "expected MalformedMeasurements"
  }

  // Telemetry saw no failing handler, so it removed nothing.
  process.receive(telemetry_failure_subject, 50) |> should.be_error()
  let _ = ffi.telemetry_detach(listener_id)

  // The handler stays attached and runs on the next well-formed event.
  native_emit(ev_name, native_map([#(key, dynamic.int(7))]), native_map([]))
  process.receive(runs, 100) |> should.equal(Ok(Nil))
  sinal.detach(att) |> should.equal(Ok(Nil))
}

pub fn malformed_metadata_invokes_failure_observer_and_keeps_handler_test() {
  let key = "str_meta"
  let str_field = fields.field(key, dynamic.string, decode.string)
  let ev_name = ["test", "malformed_meta"]
  let ev = sinal.event(ev_name, fields.empty(), str_field)
  let hid = "malformed-meta-handler"
  let failure_subject = process.new_subject()
  let on_failure = fn(selected_ev, failure) {
    process.send(failure_subject, #(sinal.name(selected_ev), failure))
  }
  let runs = process.new_subject()
  let handler = fn(_, _, _) {
    process.send(runs, Nil)
    Ok(Nil)
  }
  let assert Ok(att) =
    sinal.attach(sinal.handler([ev], handler, on_failure) |> sinal.with_id(hid))

  // Listen for native telemetry [telemetry, handler, failure]
  let failure_event = telemetry_failure_event()
  let listener_id =
    ffi.to_dynamic(atom.create("telemetry_failure_listener_meta"))
  let telemetry_failure_subject = process.new_subject()
  let listener_cb = fn(ev_name, measurements, metadata) {
    let rec = decode_failure_event(measurements, metadata)
    process.send(telemetry_failure_subject, #(ev_name, rec))
  }
  let assert Ok(Nil) =
    ffi.telemetry_attach_many(listener_id, [failure_event], listener_cb)

  // Emit raw foreign event with bad metadata (int instead of string)
  let bad_metadata = native_map([#(key, dynamic.int(999))])
  native_emit(ev_name, native_map([]), bad_metadata)

  let assert Ok(#(ev_label, failure)) = process.receive(failure_subject, 100)
  ev_label |> should.equal(["test", "malformed_meta"])
  case failure {
    sinal.MalformedMetadata(_) -> Nil
    _ -> panic as "expected MalformedMetadata"
  }

  // Telemetry saw no failing handler, so it removed nothing.
  process.receive(telemetry_failure_subject, 50) |> should.be_error()
  let _ = ffi.telemetry_detach(listener_id)

  // The handler stays attached and runs on the next well-formed event.
  native_emit(
    ev_name,
    native_map([]),
    native_map([#(key, dynamic.string("ok"))]),
  )
  process.receive(runs, 100) |> should.equal(Ok(Nil))
  sinal.detach(att) |> should.equal(Ok(Nil))
}

pub fn handler_returned_error_invokes_failure_observer_and_removes_handler_test() {
  let empty = fields.empty()
  let ev_name = ["test", "handler_error"]
  let ev = sinal.event(ev_name, empty, empty)
  let hid = "handler-return-error-test"
  let failure_subject = process.new_subject()
  let on_failure = fn(selected_ev, failure) {
    process.send(failure_subject, #(sinal.name(selected_ev), failure))
  }
  let handler = fn(_, _, _) { Error("simulated business error") }
  let assert Ok(att) =
    sinal.attach(sinal.handler([ev], handler, on_failure) |> sinal.with_id(hid))

  let failure_event = telemetry_failure_event()
  let listener_id =
    ffi.to_dynamic(atom.create("telemetry_failure_listener_return"))
  let telemetry_failure_subject = process.new_subject()
  let listener_cb = fn(ev_name, measurements, metadata) {
    let rec = decode_failure_event(measurements, metadata)
    process.send(telemetry_failure_subject, #(ev_name, rec))
  }
  let assert Ok(Nil) =
    ffi.telemetry_attach_many(listener_id, [failure_event], listener_cb)

  sinal.emit(ev, Nil, Nil)

  let assert Ok(#(ev_label, failure)) = process.receive(failure_subject, 100)
  ev_label |> should.equal(["test", "handler_error"])
  failure |> should.equal(sinal.HandlerReturned("simulated business error"))

  let assert Ok(#(actual_failure_ev_name, rec)) =
    process.receive(telemetry_failure_subject, 100)
  actual_failure_ev_name
  |> should.equal(telemetry_failure_event())
  rec.has_valid_times |> should.equal(True)
  rec.event_name |> should.equal(["test", "handler_error"])
  rec.kind |> should.equal("error")
  is_callback_failure_reason(rec.reason, "handler_returned_error")
  |> should.equal(True)
  rec.has_stacktrace |> should.equal(True)
  term_equals(rec.handler_id, ffi.to_dynamic(hid)) |> should.equal(True)
  is_function(rec.handler_config) |> should.equal(True)
  let _ = ffi.telemetry_detach(listener_id)

  sinal.detach(att) |> should.equal(Error(Nil))
}

pub fn unexpected_callback_crash_not_converted_to_typed_error_test() {
  let empty = fields.empty()
  let ev_name = ["test", "crash_not_converted"]
  let ev = sinal.event(ev_name, empty, empty)
  let hid = "unexpected-crash-handler"
  let failure_subject = process.new_subject()
  let on_failure = fn(_, failure) { process.send(failure_subject, failure) }
  let handler = fn(_, _, _) {
    // Panic causes an untyped BEAM exception
    panic as "unexpected crash"
  }
  let assert Ok(att) =
    sinal.attach(sinal.handler([ev], handler, on_failure) |> sinal.with_id(hid))

  let failure_event = telemetry_failure_event()
  let listener_id =
    ffi.to_dynamic(atom.create("telemetry_failure_listener_crash"))
  let telemetry_failure_subject = process.new_subject()
  let listener_cb = fn(ev_name, measurements, metadata) {
    let rec = decode_failure_event(measurements, metadata)
    process.send(telemetry_failure_subject, #(ev_name, rec))
  }
  let assert Ok(Nil) =
    ffi.telemetry_attach_many(listener_id, [failure_event], listener_cb)

  // Emitter receives Ok(Nil) — subscriber crash is isolated
  sinal.emit(ev, Nil, Nil)

  // on_failure was NOT called because crash was untyped BEAM exception
  process.receive(failure_subject, 50) |> should.be_error()

  // Upstream failure event fired with original panic reason
  let assert Ok(#(actual_failure_ev_name, rec)) =
    process.receive(telemetry_failure_subject, 100)
  actual_failure_ev_name
  |> should.equal(telemetry_failure_event())
  rec.has_valid_times |> should.equal(True)
  rec.event_name |> should.equal(["test", "crash_not_converted"])
  rec.kind |> should.equal("error")
  is_panic_reason(rec.reason, "unexpected crash") |> should.equal(True)
  rec.has_stacktrace |> should.equal(True)
  term_equals(rec.handler_id, ffi.to_dynamic(hid)) |> should.equal(True)
  is_function(rec.handler_config) |> should.equal(True)
  let _ = ffi.telemetry_detach(listener_id)

  // Handler was removed
  sinal.detach(att) |> should.equal(Error(Nil))
}

pub fn foreign_raw_emission_with_extra_fields_tolerated_test() {
  let ev_name = ["test", "foreign_extra_fields"]
  let ev = sinal.event(ev_name, fields.int("target_count"), fields.empty())
  let subject = process.new_subject()
  let att = sinal.observe(ev, fn(count, _) { process.send(subject, count) })

  native_emit(
    ev_name,
    native_map([
      #("target_count", dynamic.int(777)),
      #("unknown_foreign_key", dynamic.string("extra")),
    ]),
    native_map([]),
  )

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

pub type Method {
  Get
  Post
}

fn telemetry_failure_event() -> List(atom.Atom) {
  [atom.create("telemetry"), atom.create("handler"), atom.create("failure")]
}

@external(erlang, "scope_test_ffi", "native_map")
fn native_map(pairs: List(#(String, Dynamic))) -> Dynamic

@external(erlang, "scope_test_ffi", "native_emit")
fn native_emit(
  name: List(String),
  measurements: Dynamic,
  metadata: Dynamic,
) -> Nil

@external(erlang, "scope_test_ffi", "panic_message")
fn panic_message(work: fn() -> a) -> Result(String, Nil)

@external(erlang, "scope_test_ffi", "span_context_term")
fn span_context_term(context: span.SpanContext) -> Dynamic

@external(erlang, "erlang", "is_function")
fn is_function(term: Dynamic) -> Bool

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

fn with_handler(
  event: sinal.Event(m, d),
  handler: fn(sinal.Event(m, d), m, d) -> Result(Nil, e),
  reporter: fn(sinal.SubscriptionCleanupFailure) -> Nil,
  work: fn() -> a,
) -> Result(sinal.SubscriptionCompletion(a), sinal.SubscriptionScopeError) {
  sinal.subscriptions([sinal.handler([event], handler, fn(_, _) { Nil })])
  |> sinal.with_exception_cleanup_reporter(reporter)
  |> sinal.with_subscriptions(work)
}

pub fn scoped_lifetime_ordinary_completion_test() {
  let empty = fields.empty()
  let ev_name = ["scope", "ordinary"]
  let ev = sinal.event(ev_name, empty, empty)
  let subject = process.new_subject()
  let handler = fn(_, _, _) {
    process.send(subject, "handler_called")
    Ok(Nil)
  }

  let result =
    with_handler(ev, handler, fn(_) { Nil }, fn() {
      sinal.emit(ev, Nil, Nil)
      "work_value"
    })

  result
  |> should.equal(
    Ok(
      sinal.SubscriptionCompletion(
        work_result: "work_value",
        cleanup_failures: [],
      ),
    ),
  )
  process.receive(subject, 100) |> should.equal(Ok("handler_called"))

  // After scope completion, handler is detached
  sinal.emit(ev, Nil, Nil)
  process.receive(subject, 50) |> should.be_error()
}

pub fn scoped_lifetime_attach_refusal_test() {
  let empty = fields.empty()
  let ev = sinal.event(["scope", "dup"], empty, empty)
  let subject = process.new_subject()
  let holder =
    sinal.subscription(ev, fn(_, _) { Nil }) |> sinal.with_id("scope-dup-id")
  let assert Ok(held) = sinal.attach(holder)

  let result =
    sinal.with_subscriptions(sinal.subscriptions([holder]), fn() {
      process.send(subject, "should_not_run")
      "work"
    })

  result
  |> should.equal(
    Error(
      sinal.SubscriptionAttachFailed(0, sinal.AlreadyExists("scope-dup-id"), []),
    ),
  )
  process.receive(subject, 50) |> should.be_error()
  sinal.detach(held) |> should.equal(Ok(Nil))
}

pub fn scoped_lifetime_exceptional_work_cleanup_and_reraise_test() {
  let empty = fields.empty()
  let ev_name = ["scope", "exceptional"]
  let ev = sinal.event(ev_name, empty, empty)

  // 1. erlang:error/1 fidelity
  let subject_err = process.new_subject()
  let handler_err = fn(_, _, _) {
    process.send(subject_err, "called_before_crash")
    Ok(Nil)
  }
  let caught_err =
    catch_exception(fn() {
      with_handler(ev, handler_err, fn(_) { Nil }, fn() {
        sinal.emit(ev, Nil, Nil)
        raise_test_error("work_failure_error")
      })
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
  sinal.emit(ev, Nil, Nil)
  process.receive(subject_err, 50) |> should.be_error()

  // 2. erlang:exit/1 fidelity
  let subject_exit = process.new_subject()
  let handler_exit = fn(_, _, _) {
    process.send(subject_exit, "called_before_exit")
    Ok(Nil)
  }
  let caught_exit =
    catch_exception(fn() {
      with_handler(ev, handler_exit, fn(_) { Nil }, fn() {
        sinal.emit(ev, Nil, Nil)
        raise_test_exit("work_failure_exit")
      })
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
  sinal.emit(ev, Nil, Nil)
  process.receive(subject_exit, 50) |> should.be_error()

  // 3. erlang:throw/1 fidelity
  let subject_throw = process.new_subject()
  let handler_throw = fn(_, _, _) {
    process.send(subject_throw, "called_before_throw")
    Ok(Nil)
  }
  let caught_throw =
    catch_exception(fn() {
      with_handler(ev, handler_throw, fn(_) { Nil }, fn() {
        sinal.emit(ev, Nil, Nil)
        raise_test_throw("work_failure_throw")
      })
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
  sinal.emit(ev, Nil, Nil)
  process.receive(subject_throw, 50) |> should.be_error()
}

pub fn scoped_lifetime_cleanup_error_does_not_mask_work_exception_test() {
  let empty = fields.empty()
  let ev_name = ["scope", "cleanup_err_mask"]
  let ev = sinal.event(ev_name, empty, empty)
  let cleanup_failure_subject = process.new_subject()

  let handler = fn(_, _, _) {
    // Handler failure removes it from telemetry
    Error("fail_and_remove_for_detach_error")
  }
  let on_cleanup_failure = fn(failure) {
    process.send(cleanup_failure_subject, failure)
  }

  // Work throws while cleanup encounters DetachReturnedError(NotAttached)
  let caught =
    catch_exception(fn() {
      with_handler(ev, handler, on_cleanup_failure, fn() {
        sinal.emit(ev, Nil, Nil)
        raise_test_throw("work_throw_with_cleanup_error")
      })
    })

  let assert Ok(failure) = process.receive(cleanup_failure_subject, 100)
  failure
  |> should.equal(sinal.SubscriptionCleanupFailure(0, sinal.AlreadyDetached))

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
  let ev_name = ["scope", "reporter_fail"]
  let ev = sinal.event(ev_name, empty, empty)
  let cleanup_failure_subject = process.new_subject()

  let handler = fn(_, _, _) {
    // Cause handler failure so telemetry removes it before scope exit
    Error("fail_and_remove")
  }

  let on_cleanup_failure = fn(failure) {
    process.send(cleanup_failure_subject, failure)
    // Panicking inside reporter must not mask original work exception
    panic as "reporter_panicked"
  }

  // 1. Error class work exception with reporter panic
  let caught_err =
    catch_exception(fn() {
      with_handler(ev, handler, on_cleanup_failure, fn() {
        sinal.emit(ev, Nil, Nil)
        raise_test_error("original_work_error")
      })
    })
  let assert Ok(failure) = process.receive(cleanup_failure_subject, 100)
  failure
  |> should.equal(sinal.SubscriptionCleanupFailure(0, sinal.AlreadyDetached))
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
      with_handler(ev, handler, on_cleanup_failure, fn() {
        sinal.emit(ev, Nil, Nil)
        raise_test_exit("original_work_exit")
      })
    })
  let assert Ok(failure) = process.receive(cleanup_failure_subject, 100)
  failure
  |> should.equal(sinal.SubscriptionCleanupFailure(0, sinal.AlreadyDetached))
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
      with_handler(ev, handler, on_cleanup_failure, fn() {
        sinal.emit(ev, Nil, Nil)
        raise_test_throw("original_work_throw")
      })
    })
  let assert Ok(failure) = process.receive(cleanup_failure_subject, 100)
  failure
  |> should.equal(sinal.SubscriptionCleanupFailure(0, sinal.AlreadyDetached))
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
  let ev_name = ["scope", "nested"]
  let ev = sinal.event(ev_name, empty, empty)
  let outer_subject = process.new_subject()
  let inner_subject = process.new_subject()

  let outer_handler = fn(_, _, _) {
    process.send(outer_subject, "outer")
    Ok(Nil)
  }
  let inner_handler = fn(_, _, _) {
    process.send(inner_subject, "inner")
    Ok(Nil)
  }

  let outer_res =
    with_handler(ev, outer_handler, fn(_) { Nil }, fn() {
      let inner_res =
        with_handler(ev, inner_handler, fn(_) { Nil }, fn() {
          // Emit while both are active
          sinal.emit(ev, Nil, Nil)
          "inner_done"
        })
      inner_res
      |> should.equal(
        Ok(
          sinal.SubscriptionCompletion(
            work_result: "inner_done",
            cleanup_failures: [],
          ),
        ),
      )
      // Emit after inner exited — only outer should receive
      sinal.emit(ev, Nil, Nil)
      "outer_done"
    })

  outer_res
  |> should.equal(
    Ok(
      sinal.SubscriptionCompletion(
        work_result: "outer_done",
        cleanup_failures: [],
      ),
    ),
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
  let ev_name = ["scope", "already_removed"]
  let ev = sinal.event(ev_name, empty, empty)

  let handler = fn(_, _, _) {
    // Cause handler failure so telemetry detaches it
    Error("fail_handler")
  }

  let result =
    with_handler(ev, handler, fn(_) { Nil }, fn() {
      sinal.emit(ev, Nil, Nil)
      "work_survived"
    })

  result
  |> should.equal(
    Ok(
      sinal.SubscriptionCompletion(
        work_result: "work_survived",
        cleanup_failures: [
          sinal.SubscriptionCleanupFailure(0, sinal.AlreadyDetached),
        ],
      ),
    ),
  )
}

pub fn remove_all_handler_on_failure_across_events_test() {
  let empty = fields.empty()
  let ev1_name = ["multi_fail", "ev1"]
  let ev2_name = ["multi_fail", "ev2"]
  let ev1 = sinal.event(ev1_name, empty, empty)
  let ev2 = sinal.event(ev2_name, empty, empty)

  // 1. Failure via erlang:error/1 removes handler from every registered event
  let hid_err = "multi-fail-err"
  let ev2_called_err = process.new_subject()
  let handler_err = fn(selected_ev, _, _) {
    case sinal.name(selected_ev) {
      ["multi_fail", "ev1"] -> raise_test_error("fail_on_ev1_error")
      _ -> {
        process.send(ev2_called_err, "called")
        Ok(Nil)
      }
    }
  }
  let assert Ok(att_err) =
    sinal.attach(
      sinal.handler([ev1, ev2], handler_err, fn(_, _) { Nil })
      |> sinal.with_id(hid_err),
    )

  sinal.emit(ev1, Nil, Nil)
  sinal.emit(ev2, Nil, Nil)
  process.receive(ev2_called_err, 50) |> should.be_error()
  sinal.detach(att_err) |> should.equal(Error(Nil))

  // 2. Failure via erlang:exit/1 removes handler from every registered event
  let hid_exit = "multi-fail-exit"
  let ev2_called_exit = process.new_subject()
  let handler_exit = fn(selected_ev, _, _) {
    case sinal.name(selected_ev) {
      ["multi_fail", "ev1"] -> raise_test_exit("fail_on_ev1_exit")
      _ -> {
        process.send(ev2_called_exit, "called")
        Ok(Nil)
      }
    }
  }
  let assert Ok(att_exit) =
    sinal.attach(
      sinal.handler([ev1, ev2], handler_exit, fn(_, _) { Nil })
      |> sinal.with_id(hid_exit),
    )

  sinal.emit(ev1, Nil, Nil)
  sinal.emit(ev2, Nil, Nil)
  process.receive(ev2_called_exit, 50) |> should.be_error()
  sinal.detach(att_exit) |> should.equal(Error(Nil))

  // 3. Failure via erlang:throw/1 removes handler from every registered event
  let hid_throw = "multi-fail-throw"
  let ev2_called_throw = process.new_subject()
  let handler_throw = fn(selected_ev, _, _) {
    case sinal.name(selected_ev) {
      ["multi_fail", "ev1"] -> raise_test_throw("fail_on_ev1_throw")
      _ -> {
        process.send(ev2_called_throw, "called")
        Ok(Nil)
      }
    }
  }
  let assert Ok(att_throw) =
    sinal.attach(
      sinal.handler([ev1, ev2], handler_throw, fn(_, _) { Nil })
      |> sinal.with_id(hid_throw),
    )

  sinal.emit(ev1, Nil, Nil)
  sinal.emit(ev2, Nil, Nil)
  process.receive(ev2_called_throw, 50) |> should.be_error()
  sinal.detach(att_throw) |> should.equal(Error(Nil))
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
  let start_meta = {
    use method <- fields.include(fields.string("method"), get: fn(m) {
      m.method
    })
    use route <- fields.include(fields.string("route"), get: fn(m) { m.route })
    fields.success(SpanTestStartMetadata(method:, route:))
  }
  let extra_meas =
    fields.field(
      "bytes",
      fn(b: SpanTestExtraMeasurements) { dynamic.int(b.bytes) },
      decode.int |> decode.map(SpanTestExtraMeasurements),
    )
  let stop_meta =
    fields.field(
      "status",
      fn(s: SpanTestStopMetadata) { dynamic.int(s.status) },
      decode.int |> decode.map(SpanTestStopMetadata),
    )
  span.define(
    ["test_span", "op"],
    start_metadata: start_meta,
    stop_measurements: extra_meas,
    stop_metadata: stop_meta,
  )
}

pub fn span_events_derivation_test() {
  let sp = create_test_span()
  let events = span.events(sp)
  sinal.name(events.start) |> should.equal(["test_span", "op", "start"])
  sinal.name(events.stop) |> should.equal(["test_span", "op", "stop"])
  sinal.name(events.exception)
  |> should.equal(["test_span", "op", "exception"])
}

pub fn run_span_ordinary_success_test() {
  let sp = create_test_span()
  let events = span.events(sp)

  let start_subject = process.new_subject()
  let stop_subject = process.new_subject()

  let start_handler = fn(
    _ev,
    meas: span.StartMeasurements,
    meta: span.StartMetadata(SpanTestStartMetadata),
  ) {
    process.send(start_subject, #(meas, meta))
    Ok(Nil)
  }
  let stop_handler = fn(
    _ev,
    meas: span.StopMeasurements(SpanTestExtraMeasurements),
    meta: span.StopMetadata(SpanTestStopMetadata),
  ) {
    process.send(stop_subject, #(meas, meta))
    Ok(Nil)
  }

  let hid1 = "span-success-start-handler"
  let hid2 = "span-success-stop-handler"
  let assert Ok(att1) =
    sinal.attach(
      sinal.handler([events.start], start_handler, fn(_, _) { Nil })
      |> sinal.with_id(hid1),
    )
  let assert Ok(att2) =
    sinal.attach(
      sinal.handler([events.stop], stop_handler, fn(_, _) { Nil })
      |> sinal.with_id(hid2),
    )

  let result =
    span.run(
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
  is_positive_integer(
    dynamic.int(span.system_time_in(start_meas.system_time, span.Native)),
  )
  |> should.equal(True)
  is_native_integer(
    dynamic.int(span.monotonic_time_in(start_meas.monotonic_time, span.Native)),
  )
  |> should.equal(True)

  let assert Ok(#(stop_meas, stop_meta)) = process.receive(stop_subject, 100)
  stop_meas.extra.bytes |> should.equal(1024)
  stop_meta.metadata.status |> should.equal(200)
  is_non_negative_integer(
    dynamic.int(span.duration_in(stop_meas.duration, span.Native)),
  )
  |> should.equal(True)
  is_native_integer(
    dynamic.int(span.monotonic_time_in(stop_meas.monotonic_time, span.Native)),
  )
  |> should.equal(True)

  // Context equality within one invocation and native reference check
  is_native_reference(span_context_term(start_meta.context))
  |> should.equal(True)
  is_native_reference(span_context_term(stop_meta.context))
  |> should.equal(True)
  start_meta.context |> should.equal(stop_meta.context)
  term_equals(
    span_context_term(start_meta.context),
    span_context_term(stop_meta.context),
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

  let stop_handler = fn(
    _ev,
    _meas,
    meta: span.StopMetadata(SpanTestStopMetadata),
  ) {
    process.send(stop_subject, meta.metadata.status)
    Ok(Nil)
  }
  let exception_handler = fn(_ev, _meas, _meta) {
    process.send(exception_subject, "exception_called")
    Ok(Nil)
  }

  let hid_stop = "span-biz-err-stop-handler"
  let hid_exc = "span-biz-err-exc-handler"
  let assert Ok(att_stop) =
    sinal.attach(
      sinal.handler([events.stop], stop_handler, fn(_, _) { Nil })
      |> sinal.with_id(hid_stop),
    )
  let assert Ok(att_exc) =
    sinal.attach(
      sinal.handler([events.exception], exception_handler, fn(_, _) { Nil })
      |> sinal.with_id(hid_exc),
    )

  let result =
    span.run(sp, SpanTestStartMetadata(method: "POST", route: "/orders"), fn() {
      span.Completion(
        result: Error("order_validation_failed"),
        measurements: SpanTestExtraMeasurements(bytes: 0),
        metadata: SpanTestStopMetadata(status: 422),
      )
    })

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

  let start_handler = fn(
    _ev,
    _meas,
    meta: span.StartMetadata(SpanTestStartMetadata),
  ) {
    process.send(context_subject, meta.context)
    Ok(Nil)
  }
  let hid = "span-ctx-dist-handler"
  let assert Ok(att) =
    sinal.attach(
      sinal.handler([events.start], start_handler, fn(_, _) { Nil })
      |> sinal.with_id(hid),
    )

  let _ =
    span.run(sp, SpanTestStartMetadata("GET", "/first"), fn() {
      span.Completion(
        Ok(1),
        SpanTestExtraMeasurements(0),
        SpanTestStopMetadata(200),
      )
    })
  let assert Ok(ctx1) = process.receive(context_subject, 100)

  let _ =
    span.run(sp, SpanTestStartMetadata("GET", "/second"), fn() {
      span.Completion(
        Ok(2),
        SpanTestExtraMeasurements(0),
        SpanTestStopMetadata(200),
      )
    })
  let assert Ok(ctx2) = process.receive(context_subject, 100)

  // Contexts across distinct invocations must differ and be native references
  let dyn1 = span_context_term(ctx1)
  let dyn2 = span_context_term(ctx2)
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

  let start_handler = fn(
    _ev,
    _meas,
    meta: span.StartMetadata(SpanTestStartMetadata),
  ) {
    process.send(start_subject, meta)
    Ok(Nil)
  }
  let stop_handler = fn(_ev, _meas, _meta) {
    process.send(stop_subject, "stop_fired")
    Ok(Nil)
  }
  let exc_handler = fn(
    _ev,
    meas: span.ExceptionMeasurements,
    meta: span.ExceptionMetadata(SpanTestStartMetadata),
  ) {
    process.send(exc_subject, #(meas, meta))
    Ok(Nil)
  }

  let hid1 = "span-exc-start-handler"
  let hid2 = "span-exc-stop-handler"
  let hid3 = "span-exc-exc-handler"
  let assert Ok(att1) =
    sinal.attach(
      sinal.handler([events.start], start_handler, fn(_, _) { Nil })
      |> sinal.with_id(hid1),
    )
  let assert Ok(att2) =
    sinal.attach(
      sinal.handler([events.stop], stop_handler, fn(_, _) { Nil })
      |> sinal.with_id(hid2),
    )
  let assert Ok(att3) =
    sinal.attach(
      sinal.handler([events.exception], exc_handler, fn(_, _) { Nil })
      |> sinal.with_id(hid3),
    )

  // 1. Error class
  let caught_err =
    catch_exception(fn() {
      span.run(sp, SpanTestStartMetadata("POST", "/fail-error"), fn() {
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
  is_non_negative_integer(
    dynamic.int(span.duration_in(meas_err.duration, span.Native)),
  )
  |> should.equal(True)
  is_native_integer(
    dynamic.int(span.monotonic_time_in(meas_err.monotonic_time, span.Native)),
  )
  |> should.equal(True)
  is_native_reference(span_context_term(exc_meta_err.context))
  |> should.equal(True)
  term_equals(
    span_context_term(start_meta_err.context),
    span_context_term(exc_meta_err.context),
  )
  |> should.equal(True)
  term_equals(
    span.stacktrace_to_dynamic(exc_meta_err.stacktrace),
    caught_err_stack,
  )
  |> should.equal(True)
  has_origin_frame(
    span.stacktrace_to_dynamic(exc_meta_err.stacktrace),
    "scope_test_ffi",
    "raise_test_error",
  )
  |> should.equal(True)
  term_equals(
    span.reason_to_dynamic(exc_meta_err.reason),
    ffi.to_dynamic("fatal_span_error"),
  )
  |> should.equal(True)
  process.receive(stop_subject, 50) |> should.be_error()

  // 2. Exit class
  let caught_exit =
    catch_exception(fn() {
      span.run(sp, SpanTestStartMetadata("POST", "/fail-exit"), fn() {
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
  is_non_negative_integer(
    dynamic.int(span.duration_in(meas_exit.duration, span.Native)),
  )
  |> should.equal(True)
  is_native_integer(
    dynamic.int(span.monotonic_time_in(meas_exit.monotonic_time, span.Native)),
  )
  |> should.equal(True)
  is_native_reference(span_context_term(exc_meta_exit.context))
  |> should.equal(True)
  term_equals(
    span_context_term(start_meta_exit.context),
    span_context_term(exc_meta_exit.context),
  )
  |> should.equal(True)
  term_equals(
    span.stacktrace_to_dynamic(exc_meta_exit.stacktrace),
    caught_exit_stack,
  )
  |> should.equal(True)
  has_origin_frame(
    span.stacktrace_to_dynamic(exc_meta_exit.stacktrace),
    "scope_test_ffi",
    "raise_test_exit",
  )
  |> should.equal(True)
  term_equals(
    span.reason_to_dynamic(exc_meta_exit.reason),
    ffi.to_dynamic("fatal_span_exit"),
  )
  |> should.equal(True)
  process.receive(stop_subject, 50) |> should.be_error()

  // 3. Throw class
  let caught_throw =
    catch_exception(fn() {
      span.run(sp, SpanTestStartMetadata("POST", "/fail-throw"), fn() {
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
  is_non_negative_integer(
    dynamic.int(span.duration_in(meas_throw.duration, span.Native)),
  )
  |> should.equal(True)
  is_native_integer(
    dynamic.int(span.monotonic_time_in(meas_throw.monotonic_time, span.Native)),
  )
  |> should.equal(True)
  is_native_reference(span_context_term(exc_meta_throw.context))
  |> should.equal(True)
  term_equals(
    span_context_term(start_meta_throw.context),
    span_context_term(exc_meta_throw.context),
  )
  |> should.equal(True)
  term_equals(
    span.stacktrace_to_dynamic(exc_meta_throw.stacktrace),
    caught_throw_stack,
  )
  |> should.equal(True)
  has_origin_frame(
    span.stacktrace_to_dynamic(exc_meta_throw.stacktrace),
    "scope_test_ffi",
    "raise_test_throw",
  )
  |> should.equal(True)
  term_equals(
    span.reason_to_dynamic(exc_meta_throw.reason),
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
  let inner_span =
    span.define(
      ["inner_span", "call"],
      start_metadata: fields.empty(),
      stop_measurements: fields.empty(),
      stop_metadata: fields.empty(),
    )

  let outer_events = span.events(outer_span)
  let inner_events = span.events(inner_span)

  let order_subject = process.new_subject()

  let outer_start_handler = fn(
    _ev,
    _meas,
    meta: span.StartMetadata(SpanTestStartMetadata),
  ) {
    process.send(order_subject, #("outer_start", meta.context))
    Ok(Nil)
  }
  let outer_stop_handler = fn(
    _ev,
    _meas,
    meta: span.StopMetadata(SpanTestStopMetadata),
  ) {
    process.send(order_subject, #("outer_stop", meta.context))
    Ok(Nil)
  }
  let inner_start_handler = fn(_ev, _meas, meta: span.StartMetadata(Nil)) {
    process.send(order_subject, #("inner_start", meta.context))
    Ok(Nil)
  }
  let inner_stop_handler = fn(_ev, _meas, meta: span.StopMetadata(Nil)) {
    process.send(order_subject, #("inner_stop", meta.context))
    Ok(Nil)
  }

  let h1 = "nested-outer-start"
  let h2 = "nested-outer-stop"
  let h3 = "nested-inner-start"
  let h4 = "nested-inner-stop"

  let assert Ok(a1) =
    sinal.attach(
      sinal.handler([outer_events.start], outer_start_handler, fn(_, _) { Nil })
      |> sinal.with_id(h1),
    )
  let assert Ok(a2) =
    sinal.attach(
      sinal.handler([outer_events.stop], outer_stop_handler, fn(_, _) { Nil })
      |> sinal.with_id(h2),
    )
  let assert Ok(a3) =
    sinal.attach(
      sinal.handler([inner_events.start], inner_start_handler, fn(_, _) { Nil })
      |> sinal.with_id(h3),
    )
  let assert Ok(a4) =
    sinal.attach(
      sinal.handler([inner_events.stop], inner_stop_handler, fn(_, _) { Nil })
      |> sinal.with_id(h4),
    )

  let res =
    span.run(outer_span, SpanTestStartMetadata("GET", "/parent"), fn() {
      let inner_res =
        span.run(inner_span, Nil, fn() {
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
  let ev_name = ["raw_boundary", "sinal_to_raw"]
  let key = "value"
  let val_field = fields.field(key, dynamic.int, decode.int)
  let ev = sinal.event(ev_name, val_field, fields.empty())

  let subject = process.new_subject()
  let listener_id = ffi.to_dynamic(atom.create("raw_listener_for_sinal"))
  let listener_cb = fn(_name, measurements, _meta) {
    let val = case ffi.map_lookup(measurements, atom.create(key)) {
      ffi.Present(v) -> v
      _ -> ffi.to_dynamic(-1)
    }
    process.send(subject, val)
  }
  let assert Ok(Nil) =
    ffi.telemetry_attach_many(
      listener_id,
      [list.map(ev_name, atom.create)],
      listener_cb,
    )

  sinal.emit(ev, 888, Nil)

  let assert Ok(received_val) = process.receive(subject, 100)
  term_equals(received_val, dynamic.int(888)) |> should.equal(True)

  let _ = ffi.telemetry_detach(listener_id)
}

pub fn sinal_handler_observes_raw_telemetry_emission_test() {
  let ev_name = ["raw_boundary", "raw_to_sinal"]
  let key = "count"
  let count_field = fields.field(key, dynamic.int, decode.int)
  let ev = sinal.event(ev_name, count_field, fields.empty())
  let hid = "sinal-observing-raw"
  let subject = process.new_subject()

  let handler = fn(_ev, count: Int, _meta) {
    process.send(subject, count)
    Ok(Nil)
  }
  let assert Ok(att) =
    sinal.attach(
      sinal.handler([ev], handler, fn(_, _) { Nil }) |> sinal.with_id(hid),
    )

  let raw_map = native_map([#(key, dynamic.int(999))])
  native_emit(ev_name, raw_map, native_map([]))

  process.receive(subject, 100) |> should.equal(Ok(999))

  sinal.detach(att) |> should.equal(Ok(Nil))
}

pub fn synchronous_execution_in_caller_pid_and_slow_handler_blocks_test() {
  let ev_name = ["sync_test", "blocking"]
  let empty = fields.empty()
  let ev = sinal.event(ev_name, empty, empty)
  let hid = "sync-blocking-handler"
  let subject = process.new_subject()

  let handler = fn(_ev, _meas, _meta) {
    sleep(25)
    process.send(subject, "handler_finished")
    Ok(Nil)
  }
  let assert Ok(att) =
    sinal.attach(
      sinal.handler([ev], handler, fn(_, _) { Nil }) |> sinal.with_id(hid),
    )

  // When emit returns, the slow handler has already finished
  sinal.emit(ev, Nil, Nil)
  process.receive(subject, 10) |> should.equal(Ok("handler_finished"))

  sinal.detach(att) |> should.equal(Ok(Nil))
}

pub fn concurrent_emitters_test() {
  let ev_name = ["concurrency", "parallel_emit"]
  let key = "worker_id"
  let worker_field = fields.field(key, dynamic.int, decode.int)
  let ev = sinal.event(ev_name, worker_field, fields.empty())
  let hid = "concurrency-parallel-handler"
  let subject = process.new_subject()

  let handler = fn(_ev, worker_id: Int, _meta) {
    process.send(subject, worker_id)
    Ok(Nil)
  }
  let assert Ok(att) =
    sinal.attach(
      sinal.handler([ev], handler, fn(_, _) { Nil }) |> sinal.with_id(hid),
    )

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
  let ev_name = ["persist_test", "lifecycle"]
  let empty = fields.empty()
  let ev = sinal.event(ev_name, empty, empty)
  let hid1 = "persist-handler-1"
  let subject1 = process.new_subject()
  let subject2 = process.new_subject()

  let handler1 = fn(_ev, _meas, _meta) {
    process.send(subject1, "h1")
    Ok(Nil)
  }
  let assert Ok(att1) =
    sinal.attach(
      sinal.handler([ev], handler1, fn(_, _) { Nil }) |> sinal.with_id(hid1),
    )

  // Emit before persist
  sinal.emit(ev, Nil, Nil)
  process.receive(subject1, 100) |> should.equal(Ok("h1"))

  // Persist handlers (moves ETS to persistent_term)
  telemetry_persist()

  // Emit after persist still reaches handler1
  sinal.emit(ev, Nil, Nil)
  process.receive(subject1, 100) |> should.equal(Ok("h1"))

  // Attach new handler after persist
  let hid2 = "persist-handler-2"
  let handler2 = fn(_ev, _meas, _meta) {
    process.send(subject2, "h2")
    Ok(Nil)
  }
  let assert Ok(att2) =
    sinal.attach(
      sinal.handler([ev], handler2, fn(_, _) { Nil }) |> sinal.with_id(hid2),
    )

  sinal.emit(ev, Nil, Nil)
  process.receive(subject1, 100) |> should.equal(Ok("h1"))
  process.receive(subject2, 100) |> should.equal(Ok("h2"))

  sinal.detach(att1) |> should.equal(Ok(Nil))
  sinal.detach(att2) |> should.equal(Ok(Nil))
}

pub fn detach_in_flight_barrier_race_test() {
  let ev_name = ["detach_race", "in_flight"]
  let empty = fields.empty()
  let ev = sinal.event(ev_name, empty, empty)
  let hid = "in-flight-race-handler"

  let in_flight_started_subject = process.new_subject()
  let finished_subject = process.new_subject()

  let handler = fn(_ev, _meas, _meta) {
    // The executing process creates its own subject so it can receive from the coordinator
    let allow_finish_subject = process.new_subject()
    process.send(in_flight_started_subject, allow_finish_subject)
    // Block until coordinator confirms detach has executed
    let assert Ok(Nil) = process.receive(allow_finish_subject, 2000)
    process.send(finished_subject, "callback_finished")
    Ok(Nil)
  }
  let assert Ok(att) =
    sinal.attach(
      sinal.handler([ev], handler, fn(_, _) { Nil }) |> sinal.with_id(hid),
    )

  // Spawn emitter process that calls emit synchronously
  process.spawn(fn() {
    sinal.emit(ev, Nil, Nil)
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
  sinal.emit(ev, Nil, Nil)
  process.receive(in_flight_started_subject, 50) |> should.be_error()

  // Repeated detach reports NotAttached
  sinal.detach(att) |> should.equal(Error(Nil))
}

pub fn overlapping_subscriptions_order_independent_test() {
  let ev1_name = ["overlap", "ev1"]
  let ev2_name = ["overlap", "ev2"]
  let empty = fields.empty()
  let ev1 = sinal.event(ev1_name, empty, empty)
  let ev2 = sinal.event(ev2_name, empty, empty)

  let delivery_subject = process.new_subject()

  let hid1 = "overlap-handler-1"
  let hid2 = "overlap-handler-2"

  let handler1 = fn(ev, _, _) {
    process.send(delivery_subject, #("handler_1", sinal.name(ev)))
    Ok(Nil)
  }
  let handler2 = fn(ev, _, _) {
    process.send(delivery_subject, #("handler_2", sinal.name(ev)))
    Ok(Nil)
  }

  // Handler 1 listens only to ev1
  let assert Ok(att1) =
    sinal.attach(
      sinal.handler([ev1], handler1, fn(_, _) { Nil }) |> sinal.with_id(hid1),
    )
  // Handler 2 listens to both ev1 and ev2 via attach_many
  let assert Ok(att2) =
    sinal.attach(
      sinal.handler([ev1, ev2], handler2, fn(_, _) { Nil })
      |> sinal.with_id(hid2),
    )

  // Emit ev1: BOTH handlers are invoked.
  // Order between handlers is unspecified in BEAM telemetry; assert order-independently.
  sinal.emit(ev1, Nil, Nil)

  let assert Ok(msg_a) = process.receive(delivery_subject, 100)
  let assert Ok(msg_b) = process.receive(delivery_subject, 100)
  let received_ev1 = [msg_a, msg_b]
  list.contains(received_ev1, #("handler_1", ["overlap", "ev1"]))
  |> should.equal(True)
  list.contains(received_ev1, #("handler_2", ["overlap", "ev1"]))
  |> should.equal(True)

  // Emit ev2: ONLY handler 2 is invoked
  sinal.emit(ev2, Nil, Nil)
  let assert Ok(msg_c) = process.receive(delivery_subject, 100)
  msg_c |> should.equal(#("handler_2", ["overlap", "ev2"]))
  process.receive(delivery_subject, 50) |> should.be_error()

  sinal.detach(att1) |> should.equal(Ok(Nil))
  sinal.detach(att2) |> should.equal(Ok(Nil))
}

pub fn public_id_replacement_after_detach_test() {
  let ev_name = ["replace", "event"]
  let empty = fields.empty()
  let ev = sinal.event(ev_name, empty, empty)
  let hid = "reusable-handler-id"
  let subject = process.new_subject()

  let handler_v1 = fn(_, _, _) {
    process.send(subject, "v1")
    Ok(Nil)
  }
  let handler_v2 = fn(_, _, _) {
    process.send(subject, "v2")
    Ok(Nil)
  }

  let assert Ok(att1) =
    sinal.attach(
      sinal.handler([ev], handler_v1, fn(_, _) { Nil }) |> sinal.with_id(hid),
    )
  // Duplicate attach fails while attached
  sinal.attach(
    sinal.handler([ev], handler_v2, fn(_, _) { Nil }) |> sinal.with_id(hid),
  )
  |> should.equal(Error(sinal.AlreadyExists(hid)))

  // Emit invokes v1
  sinal.emit(ev, Nil, Nil)
  process.receive(subject, 100) |> should.equal(Ok("v1"))

  // Detach att1
  sinal.detach(att1) |> should.equal(Ok(Nil))

  // Now attaching with same hid succeeds
  let assert Ok(att2) =
    sinal.attach(
      sinal.handler([ev], handler_v2, fn(_, _) { Nil }) |> sinal.with_id(hid),
    )
  sinal.emit(ev, Nil, Nil)
  process.receive(subject, 100) |> should.equal(Ok("v2"))

  sinal.detach(att2) |> should.equal(Ok(Nil))
}

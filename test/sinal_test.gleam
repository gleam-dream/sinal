import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
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

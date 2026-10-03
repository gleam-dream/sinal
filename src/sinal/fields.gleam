//// Builds the typed codecs that turn a Gleam value into a native telemetry
//// map of measurements or metadata, and back.
////
//// Use this module to give a `sinal.Event` or a `sinal/span` span its
//// measurement and metadata types. `string`, `int`, `float` and `bool`
//// each declare one key; `enum` declares a key whose value is one of a
//// fixed set; `optional` makes a one-key field absent-able; `field` covers
//// any other value with an encoder and a `gleam/dynamic/decode` decoder.
//// A record codec is a `use` block: each `include` adds one field and
//// binds its value by name, and `success` builds the record. `empty`
//// declares no keys.
////
//// ```gleam
//// import sinal/fields
////
//// pub type Request {
////   Request(method: String, status: Int)
//// }
////
//// pub fn request_fields() -> fields.Fields(Request) {
////   use method <- fields.include(fields.string("method"), get: fn(r) {
////     r.method
////   })
////   use status <- fields.include(fields.int("status"), get: fn(r) { r.status })
////   fields.success(Request(method:, status:))
//// }
//// ```
////
//// Each value goes to the constructor parameter it is bound to, so the
//// fields may be listed in any order and two fields of one type cannot
//// swap. Each getter is passed with its `get:` label and needs no type
//// annotation: the rest of the block, which ends in `success`, fixes the
//// record type first. This is the shape of `json/blueprint/codec`'s
//// `field` and `success`.
////
//// ## Keys are atoms
////
//// Each key becomes an atom of the native map, and the BEAM never frees an
//// atom. A key must match `[a-z][a-z0-9_]{0,62}` and must be written in
//// source code, never built from input. A key that breaks the grammar, a
//// key declared twice in one record, an `optional` field over anything but
//// one key, and an `enum` with no values or a repeated name are definition
//// bugs: the constructor panics with a message naming the key.
////
//// ## Decoding
////
//// Decoding reads only the declared keys and ignores any others in the map.
//// It fails with a `FieldError` when the term is not a map, a required key
//// is missing, or a value does not decode. Encoding cannot fail; an `enum`
//// value missing from its list is reported when it is emitted, and `check`
//// returns the same error to a test (see `enum`).

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import sinal/internal/ffi
import sinal/internal/name as grammar

/// Why a native map did not decode. The union is closed: sinal adds no
/// variant without a major release.
pub type FieldError {
  /// The measurements or metadata term was not a map.
  NotAMap
  /// A required key was absent.
  MissingField(key: String)
  /// The value at `key` did not decode; `errors` come from its decoder.
  InvalidField(key: String, errors: List(decode.DecodeError))
}

/// A codec between a Gleam value and the keys it writes to a native map.
pub opaque type Fields(a) {
  Fields(plan: fn() -> Plan(a), decode: fn(Dynamic) -> Result(a, FieldError))
}

// What a codec writes, independent of any value. A record's plan comes from
// running its `use` block with placeholder values, once, when the record is
// defined; encoding then only calls the getters and the plans of its fields.
type Plan(a) {
  Plan(
    // The keys in declaration order.
    keys: List(Atom),
    write: fn(a, Dynamic) -> Dynamic,
    // Reports an `enum` value missing from its list; `None` when the codec
    // has no `enum`.
    check: Option(fn(a) -> Result(Nil, FieldError)),
    // Any value of `a`, used only to run a `use` block for its plan.
    placeholder: fn() -> a,
  )
}

/// Declares no keys. It decodes any map as `Nil` and rejects a term that is
/// not a map. It is the same codec as `success(Nil)`.
pub fn empty() -> Fields(Nil) {
  success(Nil)
}

/// Declares one key whose value is written by `encode` and read by
/// `decoder`. Use it for a value the other constructors do not cover.
/// Inside a record, sinal runs `decoder` once against `nil` where the
/// record is defined, for a placeholder value, so keep it free of effects.
///
/// ```gleam
/// fields.field("attempt", dynamic.int, decode.int)
/// ```
pub fn field(
  key: String,
  encode: fn(a) -> Dynamic,
  decoder: decode.Decoder(a),
) -> Fields(a) {
  single(key, "sinal/fields.field", encode, decoder, fn() { zero(decoder) })
}

/// Declares a key holding a UTF-8 binary.
pub fn string(key: String) -> Fields(String) {
  single(key, "sinal/fields.string", dynamic.string, decode.string, fn() { "" })
}

/// Declares a key holding an integer.
pub fn int(key: String) -> Fields(Int) {
  single(key, "sinal/fields.int", dynamic.int, decode.int, fn() { 0 })
}

/// Declares a key holding a float. Decoding also accepts an integer, which
/// native producers often send for a whole-number measurement, and converts
/// it.
pub fn float(key: String) -> Fields(Float) {
  single(
    key,
    "sinal/fields.float",
    dynamic.float,
    decode.one_of(decode.float, [decode.int |> decode.map(int.to_float)]),
    fn() { 0.0 },
  )
}

/// Declares a key holding a boolean.
pub fn bool(key: String) -> Fields(Bool) {
  single(key, "sinal/fields.bool", dynamic.bool, decode.bool, fn() { False })
}

/// Declares a key holding one of `values`, written as the UTF-8 binary
/// `name(value)`. Decoding accepts that binary, or an atom with the same
/// text, and fails on any other name.
///
/// The compiler checks that `name` covers every constructor, but it cannot
/// check `values`: a constructor missing from the list compiles. Encoding
/// still writes its name, and every emit path (`sinal.emit`,
/// `forwarder.emit`, `span.run`) logs a warning in the emitting process
/// that names the event and the value. Every sinal handler of the event
/// then fails to decode it, reports `MalformedMetadata` (or
/// `MalformedMeasurements`) to its failure observer, skips that one
/// invocation and stays attached. The event is lost to typed handlers
/// until the list is fixed.
///
/// So keep `values` next to the type, and give the application a test that
/// names every constructor and round-trips it through the codec. The
/// compiler cannot list a type's constructors, so the test names them
/// itself; when it names one that `values` lacks, `check` returns the error
/// and the decode fails:
///
/// ```gleam
/// pub fn every_method_is_listed_test() {
///   let codec = method_field()
///   // One entry per constructor of Method.
///   list.each([Get, Post], fn(method) {
///     let assert Ok(Nil) = fields.check(codec, method)
///     let assert Ok(decoded) =
///       fields.decode(codec, fields.encode(codec, method))
///     assert decoded == method
///   })
/// }
/// ```
///
/// ```gleam
/// pub type Method {
///   Get
///   Post
/// }
///
/// fields.enum("method", [Get, Post], fn(method) {
///   case method {
///     Get -> "get"
///     Post -> "post"
///   }
/// })
/// ```
///
/// Panics when `values` is empty or two values share a name.
pub fn enum(key: String, values: List(a), name: fn(a) -> String) -> Fields(a) {
  let named = list.map(values, fn(value) { #(name(value), value) })
  let names = list.map(named, fn(pair) { pair.0 })
  let first = case values {
    [first, ..] -> first
    [] ->
      panic as {
        "sinal/fields.enum: key " <> string.inspect(key) <> " has no values"
      }
  }
  case first_duplicate(names, []) {
    Ok(duplicate) ->
      panic as {
        "sinal/fields.enum: key "
        <> string.inspect(key)
        <> " gives two values the name "
        <> string.inspect(duplicate)
      }
    Error(Nil) -> Nil
  }
  let expected = "one of " <> string.join(names, ", ")
  let decoder =
    decode.one_of(decode.string, [atom.decoder() |> decode.map(atom.to_string)])
    |> decode.then(fn(found) {
      case list.key_find(named, found) {
        Ok(value) -> decode.success(value)
        Error(Nil) -> decode.failure(first, expected)
      }
    })
  let field =
    single(
      key,
      "sinal/fields.enum",
      fn(value) { dynamic.string(name(value)) },
      decoder,
      fn() { first },
    )
  let check = fn(value) {
    let found = name(value)
    case list.contains(names, found) {
      True -> Ok(Nil)
      False ->
        Error(
          InvalidField(key, [
            decode.DecodeError(
              expected:,
              found: string.inspect(found),
              path: [],
            ),
          ]),
        )
    }
  }
  let plan = Plan(..field.plan(), check: Some(check))
  Fields(..field, plan: fn() { plan })
}

/// Makes a one-key field absent-able. Encoding `None` omits the key.
/// Decoding reads a missing key, or the atom `nil` or `undefined` that a
/// native producer may write instead, as `None`; any other value decodes
/// through `inner`.
///
/// Do not wrap an `inner` whose own encoded values include the atoms `nil`
/// or `undefined`: they would decode as `None`.
///
/// Panics when `inner` declares other than exactly one key.
pub fn optional(inner: Fields(a)) -> Fields(Option(a)) {
  let inner_plan = inner.plan()
  let key = case inner_plan.keys {
    [key] -> key
    other ->
      panic as {
        "sinal/fields.optional: the inner field must declare exactly one key, got "
        <> string.inspect(list.map(other, atom.to_string))
      }
  }
  let plan =
    Plan(
      keys: inner_plan.keys,
      write: fn(value, map) {
        case value {
          None -> map
          Some(actual) -> inner_plan.write(actual, map)
        }
      },
      check: option.map(inner_plan.check, fn(check) {
        fn(value) {
          case value {
            None -> Ok(Nil)
            Some(actual) -> check(actual)
          }
        }
      }),
      placeholder: fn() { None },
    )
  Fields(plan: fn() { plan }, decode: fn(raw) {
    case ffi.map_lookup(raw, key) {
      ffi.NotAMap -> Error(NotAMap)
      ffi.Absent -> Ok(None)
      ffi.Present(value) ->
        case ffi.is_missing_marker(value) {
          True -> Ok(None)
          False ->
            case inner.decode(raw) {
              Ok(value) -> Ok(Some(value))
              Error(error) -> Error(error)
            }
        }
    }
  })
}

/// Adds one field to a record codec and binds its decoded value by name for
/// the rest of the `use` block, which ends in `success`:
///
/// ```gleam
/// use status <- fields.include(fields.int("status"), get: fn(r) { r.status })
/// ```
///
/// `field` writes its keys from the value that `get` reads from the record.
/// It is usually one key, but it can be another record codec, whose keys
/// are written into the same map. The fields of a record may be listed in
/// any order: each value goes to the constructor parameter it is bound to.
///
/// Pass the getter with its `get:` label. Gleam checks arguments in
/// parameter order, and `next` (the rest of the `use` block) comes before
/// `get`, so the record type is known from `success` by the time the getter
/// is checked and the getter needs no annotation. Without the label the
/// getter fills the `then` slot and the call fails to compile.
///
/// The record's keys and encoder are fixed once, where the record is
/// defined, by running the `use` block with placeholder values: the zero
/// value of each field's decoder (`fields.field` runs its decoder against
/// `nil` for it). So keep the block to `include` calls and a `success`
/// constructor, and do not choose a field from a value bound before it.
/// Decoding runs the block again with the decoded values.
///
/// Panics when `field` declares a key the rest of the record already has.
pub fn include(
  field: Fields(a),
  then next: fn(a) -> Fields(r),
  get get: fn(r) -> a,
) -> Fields(r) {
  let decode = fn(raw) {
    case field.decode(raw) {
      Error(error) -> Error(error)
      Ok(value) -> next(value).decode(raw)
    }
  }
  // Decoding runs the block again with the decoded values, and the records
  // it builds then only decode: their plans stay unbuilt, so a decode costs
  // one pass over the block instead of one pass per field.
  case ffi.is_decoding() {
    True -> Fields(plan: fn() { include_plan(field, next, get) }, decode:)
    False -> {
      let plan = include_plan(field, next, get)
      Fields(plan: fn() { plan }, decode:)
    }
  }
}

fn include_plan(
  field: Fields(a),
  next: fn(a) -> Fields(r),
  get: fn(r) -> a,
) -> Plan(r) {
  let own = field.plan()
  let rest = next(own.placeholder()).plan()
  case list.find(own.keys, list.contains(rest.keys, _)) {
    Ok(duplicate) ->
      panic as {
        "sinal/fields.include: key "
        <> string.inspect(atom.to_string(duplicate))
        <> " is declared twice in one record"
      }
    Error(Nil) -> Nil
  }
  Plan(
    keys: list.append(own.keys, rest.keys),
    write: fn(record, map) { rest.write(record, own.write(get(record), map)) },
    check: case own.check, rest.check {
      None, None -> None
      Some(check), None -> Some(fn(record) { check(get(record)) })
      None, Some(_) -> rest.check
      Some(check), Some(others) ->
        Some(fn(record) {
          case check(get(record)) {
            Ok(Nil) -> others(record)
            Error(error) -> Error(error)
          }
        })
    },
    placeholder: rest.placeholder,
  )
}

/// Ends a record codec with the record built from the values that the
/// `include` calls before it bound:
///
/// ```gleam
/// pub fn request_fields() -> fields.Fields(Request) {
///   use method <- fields.include(fields.string("method"), get: fn(r) {
///     r.method
///   })
///   use status <- fields.include(fields.int("status"), get: fn(r) { r.status })
///   fields.success(Request(method:, status:))
/// }
/// ```
///
/// Alone, `success(value)` declares no keys and decodes any map as `value`.
pub fn success(value: r) -> Fields(r) {
  let plan =
    Plan(keys: [], write: fn(_, map) { map }, check: None, placeholder: fn() {
      value
    })
  Fields(plan: fn() { plan }, decode: fn(raw) {
    case ffi.is_map(raw) {
      True -> Ok(value)
      False -> Error(NotAMap)
    }
  })
}

/// The keys `fields` writes, in declaration order.
pub fn keys(fields: Fields(a)) -> List(String) {
  list.map(fields.plan().keys, atom.to_string)
}

/// Encodes `value` into the native map that `sinal.emit` would send. Use it
/// to pin a package's wire format in tests or to hand a map to Erlang code.
/// It writes an `enum` value missing from its list without complaint; the
/// emit paths report it.
pub fn encode(fields: Fields(a), value: a) -> Dynamic {
  fields.plan().write(value, ffi.empty_map())
}

/// Reports a value that every sinal handler would fail to decode although
/// it encodes: an `enum` value missing from its list, anywhere in `fields`.
/// It returns the `InvalidField` error the handler would report, and
/// `Ok(Nil)` for any other value. The emit paths log a warning for the
/// same values; `check` only returns the error, so a test can assert it.
///
/// ```gleam
/// fields.check(method_field(), Delete)
/// // -> Error(InvalidField("method", [..])) when Delete is not listed
/// ```
pub fn check(fields: Fields(a), value: a) -> Result(Nil, FieldError) {
  case fields.plan().check {
    None -> Ok(Nil)
    Some(check) -> check(value)
  }
}

/// Decodes a native map the way a handler would, reading only the
/// declared keys.
pub fn decode(fields: Fields(a), raw: Dynamic) -> Result(a, FieldError) {
  ffi.decoding(fn() { fields.decode(raw) })
}

/// Describes a decoding failure for logs.
pub fn describe_error(error: FieldError) -> String {
  case error {
    NotAMap -> "expected a native map"
    MissingField(key) -> "missing key " <> key
    InvalidField(key, errors) ->
      "invalid value at key "
      <> key
      <> ": "
      <> string.join(list.map(errors, describe_decode_error), "; ")
  }
}

fn describe_decode_error(error: decode.DecodeError) -> String {
  let decode.DecodeError(expected:, found:, path:) = error
  let at = case path {
    [] -> ""
    _ -> " at " <> string.join(path, ".")
  }
  "expected " <> expected <> ", found " <> found <> at
}

fn single(
  key: String,
  caller: String,
  encode: fn(a) -> Dynamic,
  decoder: decode.Decoder(a),
  placeholder: fn() -> a,
) -> Fields(a) {
  // A decode runs a record's `use` block again with the decoded values; the
  // keys it builds were checked when the record was defined.
  let native_key = case ffi.is_decoding() {
    True -> atom.create(key)
    False -> grammar.to_atom(key, caller:, what: "key")
  }
  let plan =
    Plan(
      keys: [native_key],
      write: fn(value, map) { ffi.map_put(map, native_key, encode(value)) },
      check: None,
      placeholder:,
    )
  Fields(plan: fn() { plan }, decode: fn(raw) {
    case ffi.map_lookup(raw, native_key) {
      ffi.NotAMap -> Error(NotAMap)
      ffi.Absent -> Error(MissingField(key))
      ffi.Present(value) ->
        case decode.run(value, decoder) {
          Ok(decoded) -> Ok(decoded)
          Error(errors) -> Error(InvalidField(key, errors))
        }
    }
  })
}

/// A value of `a` from `decoder`. A `gleam/dynamic/decode` decoder that
/// fails still returns a value of its type (the zero value of `failure`),
/// so this ignores the errors of a run against `nil`.
fn zero(decoder: decode.Decoder(a)) -> a {
  let assert Ok(value) =
    decode.run(dynamic.nil(), decode.map_errors(decoder, fn(_) { [] }))
  value
}

fn first_duplicate(
  names: List(String),
  seen: List(String),
) -> Result(String, Nil) {
  case names {
    [] -> Error(Nil)
    [name, ..rest] ->
      case list.contains(seen, name) {
        True -> Ok(name)
        False -> first_duplicate(rest, [name, ..seen])
      }
  }
}

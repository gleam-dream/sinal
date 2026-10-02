//// Builds the typed codecs that turn a Gleam value into a native telemetry
//// map of measurements or metadata, and back.
////
//// Use this module to give a `sinal.Event` or a `sinal/span` span its
//// measurement and metadata types. `string`, `int`, `float` and `bool`
//// each declare one key; `enum` declares a key whose value is one of a
//// fixed set; `optional` makes a one-key field absent-able; `field` covers
//// any other value with an encoder and a `gleam/dynamic/decode` decoder.
//// `record`, `parameter`, `and` and `build` join several fields into one
//// record, one line per field. `empty` declares no keys.
////
//// ```gleam
//// import sinal/fields
////
//// pub type Request {
////   Request(method: String, status: Int)
//// }
////
//// pub fn request_fields() -> fields.Fields(Request) {
////   fields.record({
////     use method <- fields.parameter
////     use status <- fields.parameter
////     Request(method:, status:)
////   })
////   |> fields.and(fields.string("method"), fn(r: Request) { r.method })
////   |> fields.and(fields.int("status"), fn(r) { r.status })
////   |> fields.build
//// }
//// ```
////
//// Only the first getter needs a type annotation: the record type is not
//// known until `build`.
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
//// value missing from its list is reported when it is emitted (see
//// `enum`).

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
  Fields(
    keys: List(Atom),
    put: fn(a, Dynamic) -> Dynamic,
    decode: fn(Dynamic) -> Result(a, FieldError),
    check: Option(fn(a) -> Result(Nil, FieldError)),
  )
}

/// Declares no keys. It decodes any map as `Nil` and rejects a term that is
/// not a map.
pub fn empty() -> Fields(Nil) {
  Fields(
    keys: [],
    put: fn(_, map) { map },
    decode: fn(raw) {
      case ffi.is_map(raw) {
        True -> Ok(Nil)
        False -> Error(NotAMap)
      }
    },
    check: None,
  )
}

/// Declares one key whose value is written by `encode` and read by
/// `decoder`. Use it for a value the other constructors do not cover.
///
/// ```gleam
/// fields.field("attempt", dynamic.int, decode.int)
/// ```
pub fn field(
  key: String,
  encode: fn(a) -> Dynamic,
  decoder: decode.Decoder(a),
) -> Fields(a) {
  single(key, "sinal/fields.field", encode, decoder)
}

/// Declares a key holding a UTF-8 binary.
pub fn string(key: String) -> Fields(String) {
  single(key, "sinal/fields.string", dynamic.string, decode.string)
}

/// Declares a key holding an integer.
pub fn int(key: String) -> Fields(Int) {
  single(key, "sinal/fields.int", dynamic.int, decode.int)
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
  )
}

/// Declares a key holding a boolean.
pub fn bool(key: String) -> Fields(Bool) {
  single(key, "sinal/fields.bool", dynamic.bool, decode.bool)
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
/// until the list is fixed, so keep `values` next to the type and add a
/// test that emits each constructor.
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
  let decoder =
    decode.one_of(decode.string, [atom.decoder() |> decode.map(atom.to_string)])
    |> decode.then(fn(found) {
      case list.key_find(named, found) {
        Ok(value) -> decode.success(value)
        Error(Nil) -> decode.failure(first, expected)
      }
    })
  Fields(
    ..single(
      key,
      "sinal/fields.enum",
      fn(value) { dynamic.string(name(value)) },
      decoder,
    ),
    check: Some(check),
  )
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
  let key = case inner.keys {
    [key] -> key
    other ->
      panic as {
        "sinal/fields.optional: the inner field must declare exactly one key, got "
        <> string.inspect(list.map(other, atom.to_string))
      }
  }
  Fields(
    keys: inner.keys,
    put: fn(value, map) {
      case value {
        None -> map
        Some(actual) -> inner.put(actual, map)
      }
    },
    decode: fn(raw) {
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
    },
    check: option.map(inner.check, fn(check) {
      fn(value) {
        case value {
          None -> Ok(Nil)
          Some(actual) -> check(actual)
        }
      }
    }),
  )
}

/// A record codec under construction. `record` starts it, each `and` adds a
/// field and consumes one parameter of the constructor, and `build` ends it.
pub opaque type Record(record, constructor) {
  Record(
    keys: List(Atom),
    puts: List(fn(record, Dynamic) -> Dynamic),
    decode: fn(Dynamic) -> Result(constructor, FieldError),
    checks: List(fn(record) -> Result(Nil, FieldError)),
  )
}

/// Starts a record codec from a curried constructor, usually written with
/// `use x <- fields.parameter` for each field.
pub fn record(constructor: constructor) -> Record(record, constructor) {
  Record(
    keys: [],
    puts: [],
    decode: fn(raw) {
      case ffi.is_map(raw) {
        True -> Ok(constructor)
        False -> Error(NotAMap)
      }
    },
    checks: [],
  )
}

/// Turns the rest of a `use` block into one parameter of a curried record
/// constructor.
pub fn parameter(next: fn(a) -> rest) -> fn(a) -> rest {
  next
}

/// Adds the next field of the record: `field` encodes and decodes the
/// value, and `get` reads it from the record when encoding. Add fields in
/// the constructor's parameter order.
///
/// Panics when `field` declares a key the record already has.
pub fn and(
  record: Record(record, fn(a) -> rest),
  field: Fields(a),
  get: fn(record) -> a,
) -> Record(record, rest) {
  case list.find(field.keys, fn(key) { list.contains(record.keys, key) }) {
    Ok(duplicate) ->
      panic as {
        "sinal/fields.and: key "
        <> string.inspect(atom.to_string(duplicate))
        <> " is declared twice in one record"
      }
    Error(Nil) -> Nil
  }
  let previous = record.decode
  Record(
    keys: list.append(record.keys, field.keys),
    puts: [fn(value, map) { field.put(get(value), map) }, ..record.puts],
    decode: fn(raw) {
      case previous(raw) {
        Error(error) -> Error(error)
        Ok(constructor) ->
          case field.decode(raw) {
            Error(error) -> Error(error)
            Ok(value) -> Ok(constructor(value))
          }
      }
    },
    checks: case field.check {
      None -> record.checks
      Some(check) -> [fn(value) { check(get(value)) }, ..record.checks]
    },
  )
}

/// Ends a record codec once every constructor parameter has a field.
pub fn build(record: Record(record, record)) -> Fields(record) {
  let puts = list.reverse(record.puts)
  Fields(
    keys: record.keys,
    put: fn(value, map) {
      list.fold(puts, map, fn(map, put) { put(value, map) })
    },
    decode: record.decode,
    check: case list.reverse(record.checks) {
      [] -> None
      checks ->
        Some(fn(value) { list.try_each(checks, fn(check) { check(value) }) })
    },
  )
}

/// The keys `fields` writes, in declaration order.
pub fn keys(fields: Fields(a)) -> List(String) {
  list.map(fields.keys, atom.to_string)
}

/// Encodes `value` into the native map that `sinal.emit` would send. Use it
/// to pin a package's wire format in tests or to hand a map to Erlang code.
/// It writes an `enum` value missing from its list without complaint; the
/// emit paths report it.
pub fn encode(fields: Fields(a), value: a) -> Dynamic {
  fields.put(value, ffi.empty_map())
}

/// Encodes `value` for an emit path. When an `enum` value is missing from
/// its list, it logs a warning that names `caller` and the event (`event`
/// runs only then), and still writes the name, so Erlang and Elixir
/// handlers receive it.
@internal
pub fn encode_for_emit(
  fields: Fields(a),
  value: a,
  caller caller: String,
  event event: fn() -> List(String),
) -> Dynamic {
  case fields.check {
    None -> Nil
    Some(check) ->
      case check(value) {
        Ok(Nil) -> Nil
        Error(error) ->
          ffi.log_warning(
            caller
            <> ": event "
            <> string.inspect(event())
            <> " carries a value that its fields.enum list does not name ("
            <> describe_error(error)
            <> "); every sinal handler of the event will skip it as malformed",
          )
      }
  }
  fields.put(value, ffi.empty_map())
}

/// Decodes a native map the way a handler would, reading only the
/// declared keys.
pub fn decode(fields: Fields(a), raw: Dynamic) -> Result(a, FieldError) {
  fields.decode(raw)
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
) -> Fields(a) {
  let native_key = grammar.to_atom(key, caller:, what: "key")
  Fields(
    check: None,
    keys: [native_key],
    put: fn(value, map) { ffi.map_put(map, native_key, encode(value)) },
    decode: fn(raw) {
      case ffi.map_lookup(raw, native_key) {
        ffi.NotAMap -> Error(NotAMap)
        ffi.Absent -> Error(MissingField(key))
        ffi.Present(value) ->
          case decode.run(value, decoder) {
            Ok(decoded) -> Ok(decoded)
            Error(errors) -> Error(InvalidField(key, errors))
          }
      }
    },
  )
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

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/option.{type Option, None, Some}
import sinal/internal/ffi

pub type FieldError {
  MissingField(name: String)
  DuplicateField(name: String)
  InvalidField(name: String, error: FieldDecodeError)
  InvalidOptionalInner(names: List(String))
}

pub type FieldDecodeError {
  FieldDecodeError(message: String)
}

pub type FieldEncodeError {
  FieldEncodeError(message: String)
}

pub opaque type Fields(a) {
  Fields(
    keys: List(Atom),
    encode_fn: fn(a) -> Result(Dynamic, FieldEncodeError),
    decode_fn: fn(Dynamic) -> Result(a, FieldError),
  )
}

/// The empty field group: contributes no keys, rejects non-map terms at the boundary,
/// and tolerates any foreign fields in a valid map.
pub fn empty() -> Fields(Nil) {
  Fields(
    keys: [],
    encode_fn: fn(_nil) { Ok(ffi.empty_map()) },
    decode_fn: fn(raw_map) {
      case ffi.is_map(raw_map) {
        True -> Ok(Nil)
        False ->
          Error(InvalidField("", FieldDecodeError("Expected a native BEAM map")))
      }
    },
  )
}

/// Canonical constructor for a custom native field backed by a trusted BEAM atom key.
/// Field identity is derived strictly from the atom. Encoding is fallible.
/// Unrelated foreign fields present in a valid map are ignored.
pub fn field(
  key: Atom,
  encode: fn(a) -> Result(Dynamic, FieldEncodeError),
  decode: fn(Dynamic) -> Result(a, FieldDecodeError),
) -> Fields(a) {
  let name = atom.to_string(key)
  Fields(
    keys: [key],
    encode_fn: fn(item) {
      case encode(item) {
        Ok(val) -> Ok(ffi.map_from_pair(key, val))
        Error(err) -> Error(err)
      }
    },
    decode_fn: fn(raw_map) {
      case ffi.is_map(raw_map) {
        False ->
          Error(InvalidField(
            name,
            FieldDecodeError("Expected a native BEAM map"),
          ))
        True ->
          case ffi.map_get(raw_map, key) {
            Error(Nil) -> Error(MissingField(name))
            Ok(raw_val) ->
              case decode(raw_val) {
                Ok(item) -> Ok(item)
                Error(err) -> Error(InvalidField(name, err))
              }
          }
      }
    },
  )
}

/// Declares a native string field from a trusted, application-defined atom key.
pub fn string(key: Atom) -> Fields(String) {
  field(key, fn(value) { Ok(dynamic.string(value)) }, fn(raw) {
    case decode.run(raw, decode.string) {
      Ok(value) -> Ok(value)
      Error(_) -> Error(FieldDecodeError("Expected a native BEAM string"))
    }
  })
}

/// Declares a native integer field from a trusted, application-defined atom key.
pub fn int(key: Atom) -> Fields(Int) {
  field(key, fn(value) { Ok(dynamic.int(value)) }, fn(raw) {
    case decode.run(raw, decode.int) {
      Ok(value) -> Ok(value)
      Error(_) -> Error(FieldDecodeError("Expected a native BEAM integer"))
    }
  })
}

/// Declares a native boolean field from a trusted, application-defined atom key.
pub fn bool(key: Atom) -> Fields(Bool) {
  field(key, fn(value) { Ok(dynamic.bool(value)) }, fn(raw) {
    case decode.run(raw, decode.bool) {
      Ok(value) -> Ok(value)
      Error(_) -> Error(FieldDecodeError("Expected a native BEAM boolean"))
    }
  })
}

/// Wraps a single-key field so its absence is a genuine option rather than a
/// decode failure: a missing native key, or a present raw `nil`/`undefined`
/// marker value at that key, decodes as `None`; any other present value
/// decodes and encodes through `inner`. Encoding `None` omits the key
/// entirely, so a foreign consumer sees no key rather than an explicit
/// marker.
///
/// `inner` must declare exactly one native key, since presence is checked at
/// that one key; an `inner` with zero or more than one key (`fields.empty()`,
/// a `pair`, ...) is rejected with `InvalidOptionalInner` rather than
/// silently doing the wrong thing.
///
/// This cannot distinguish a genuinely absent value from a present value
/// that `inner` itself would encode as the atom `nil` or `undefined` — for
/// example, wrapping Gleam's own `Nil` through `fields.field` as a
/// legitimate non-absent payload. Do not compose `optional` with an `inner`
/// whose valid encoded values include those two markers.
pub fn optional(inner: Fields(a)) -> Result(Fields(Option(a)), FieldError) {
  case inner.keys {
    [key] -> Ok(build_optional(key, inner))
    other -> Error(InvalidOptionalInner(list.map(other, atom.to_string)))
  }
}

fn build_optional(key: Atom, inner: Fields(a)) -> Fields(Option(a)) {
  let name = atom.to_string(key)
  Fields(
    keys: inner.keys,
    encode_fn: fn(value) {
      case value {
        None -> Ok(ffi.empty_map())
        Some(actual) -> inner.encode_fn(actual)
      }
    },
    decode_fn: fn(raw_map) {
      case ffi.is_map(raw_map) {
        False ->
          Error(InvalidField(
            name,
            FieldDecodeError("Expected a native BEAM map"),
          ))
        True ->
          case ffi.map_get(raw_map, key) {
            Error(Nil) -> Ok(None)
            Ok(raw_val) ->
              case ffi.is_missing_marker(raw_val) {
                True -> Ok(None)
                False ->
                  case inner.decode_fn(raw_map) {
                    Ok(value) -> Ok(Some(value))
                    Error(err) -> Error(err)
                  }
              }
          }
      }
    },
  )
}

/// Composes two field specifications. Rejects duplicate declared native keys.
pub fn pair(
  left: Fields(a),
  right: Fields(b),
) -> Result(Fields(#(a, b)), FieldError) {
  case check_duplicate_keys(left.keys, right.keys) {
    Error(dup) -> Error(DuplicateField(atom.to_string(dup)))
    Ok(Nil) ->
      Ok(
        Fields(
          keys: list.append(left.keys, right.keys),
          encode_fn: fn(pair_val: #(a, b)) {
            case left.encode_fn(pair_val.0) {
              Error(err) -> Error(err)
              Ok(map_a) ->
                case right.encode_fn(pair_val.1) {
                  Error(err) -> Error(err)
                  Ok(map_b) -> Ok(ffi.map_merge(map_a, map_b))
                }
            }
          },
          decode_fn: fn(raw_map) {
            case left.decode_fn(raw_map) {
              Error(err) -> Error(err)
              Ok(val_a) ->
                case right.decode_fn(raw_map) {
                  Error(err) -> Error(err)
                  Ok(val_b) -> Ok(#(val_a, val_b))
                }
            }
          },
        ),
      )
  }
}

/// Re-expresses a field set with a different Gleam type using bidirectional mapping.
pub fn imap(fields: Fields(a), from: fn(a) -> b, to: fn(b) -> a) -> Fields(b) {
  Fields(
    keys: fields.keys,
    encode_fn: fn(val_b) { fields.encode_fn(to(val_b)) },
    decode_fn: fn(raw_map) {
      case fields.decode_fn(raw_map) {
        Ok(val_a) -> Ok(from(val_a))
        Error(err) -> Error(err)
      }
    },
  )
}

/// Returns the declared logical field labels derived from the native keys.
pub fn declared_keys(fields: Fields(a)) -> List(String) {
  list.map(fields.keys, atom.to_string)
}

/// Returns the declared native atom keys.
pub fn declared_native_keys(fields: Fields(a)) -> List(Atom) {
  fields.keys
}

/// Encodes a value into a native BEAM map with error propagation.
pub fn encode(fields: Fields(a), item: a) -> Result(Dynamic, FieldEncodeError) {
  fields.encode_fn(item)
}

/// Decodes a value from a native BEAM map, rejecting non-map terms and ignoring unrelated foreign keys.
pub fn decode(fields: Fields(a), raw_map: Dynamic) -> Result(a, FieldError) {
  fields.decode_fn(raw_map)
}

fn check_duplicate_keys(
  left: List(Atom),
  right: List(Atom),
) -> Result(Nil, Atom) {
  case left {
    [] -> Ok(Nil)
    [head, ..tail] ->
      case list.contains(right, head) {
        True -> Error(head)
        False -> check_duplicate_keys(tail, right)
      }
  }
}

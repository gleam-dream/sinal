import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import sinal/internal/ffi

pub type FieldError {
  MissingField(name: String)
  DuplicateField(name: String)
  InvalidField(name: String, error: FieldDecodeError)
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

/// Declares a single native field backed by a trusted BEAM atom key.
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

/// Declares a single native field backed by a trusted BEAM atom key.
pub fn native_field(
  key: Atom,
  encode: fn(a) -> Result(Dynamic, FieldEncodeError),
  decode: fn(Dynamic) -> Result(a, FieldDecodeError),
) -> Fields(a) {
  field(key, encode, decode)
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

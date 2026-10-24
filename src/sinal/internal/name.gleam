//// Checks the event name segments and field keys that sinal turns into
//// atoms. Names are definitions written in source code, so a name that
//// breaks the grammar is a programmer error and panics with the offending
//// value.

import gleam/erlang/atom.{type Atom}
import gleam/string

/// The grammar every name segment and field key must match.
pub const grammar = "[a-z][a-z0-9_]{0,62}"

/// Returns the atom for `value`, or panics naming `caller`, `what` and the
/// value when it breaks the grammar.
pub fn to_atom(
  value: String,
  caller caller: String,
  what what: String,
) -> Atom {
  case is_valid(value) {
    True -> atom.create(value)
    False ->
      panic as {
        caller
        <> ": invalid "
        <> what
        <> " "
        <> string.inspect(value)
        <> "; it must match "
        <> grammar
        <> ". Names and keys become atoms, so write them in source code and never build them from input."
      }
  }
}

pub fn is_valid(value: String) -> Bool {
  case value {
    "" -> False
    _ ->
      case string.byte_size(value) > 63 {
        True -> False
        False -> valid_bytes(<<value:utf8>>, True)
      }
  }
}

fn valid_bytes(bytes: BitArray, first: Bool) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bits>> ->
      case is_lower(byte) || { !first && { is_digit(byte) || byte == 95 } } {
        True -> valid_bytes(rest, False)
        False -> False
      }
    _ -> False
  }
}

fn is_lower(byte: Int) -> Bool {
  byte >= 97 && byte <= 122
}

fn is_digit(byte: Int) -> Bool {
  byte >= 48 && byte <= 57
}

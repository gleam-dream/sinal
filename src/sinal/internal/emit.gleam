import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import gleam/string
import sinal/diagnostic
import sinal/fields.{type Fields}

/// Encodes `value` for an emit path. When an `enum` value is missing from
/// its list, it reports an `UnlistedValue` diagnostic for the event
/// (`event` runs only then) that names `caller`, and still writes the
/// name, so Erlang and Elixir handlers receive it.
pub fn encode(
  fields: Fields(a),
  value: a,
  caller caller: String,
  event event: fn() -> List(Atom),
) -> Dynamic {
  case fields.check(fields, value) {
    Ok(Nil) -> Nil
    Error(error) -> {
      let name = event()
      diagnostic.report(diagnostic.UnlistedValue, name:, describe: fn() {
        caller
        <> ": event "
        <> string.inspect(list.map(name, atom.to_string))
        <> " carries a value that its fields.enum list does not name ("
        <> fields.describe_error(error)
        <> "); every sinal handler of the event will skip it as malformed"
      })
    }
  }
  fields.encode(fields, value)
}

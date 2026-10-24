import gleam/dynamic.{type Dynamic}
import gleam/string
import sinal/fields.{type Fields}
import sinal/internal/ffi

/// Encodes `value` for an emit path. When an `enum` value is missing from
/// its list, it logs a warning that names `caller` and the event (`event`
/// runs only then), and still writes the name, so Erlang and Elixir
/// handlers receive it.
pub fn encode(
  fields: Fields(a),
  value: a,
  caller caller: String,
  event event: fn() -> List(String),
) -> Dynamic {
  case fields.check(fields, value) {
    Ok(Nil) -> Nil
    Error(error) ->
      ffi.log_warning(
        caller
        <> ": event "
        <> string.inspect(event())
        <> " carries a value that its fields.enum list does not name ("
        <> fields.describe_error(error)
        <> "); every sinal handler of the event will skip it as malformed",
      )
  }
  fields.encode(fields, value)
}

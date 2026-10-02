//// The correlation value that every gleam-dream package carries in its
//// event metadata, so one unit of work can be followed across packages.
////
//// A `Correlation` is an opaque string of 1 to 128 bytes. It can be any
//// application id (an order id, a job id, a request id), a value read from
//// an untrusted header with `from_string`, or a fresh `unique()` value. A
//// W3C trace id (32 lowercase hexadecimal characters) is a valid
//// correlation, and `unique()` returns one of that shape, so a tracing
//// adapter can use the trace id as the correlation.
////
//// ## The metadata field
////
//// `field()` is the one codec for it: the key `correlation`, holding a
//// UTF-8 binary, omitted when there is none. An Erlang or Elixir handler
//// reads `metadata.correlation` without knowing which package emitted the
//// event.
////
//// ```gleam
//// import gleam/option.{type Option}
//// import sinal/correlation.{type Correlation}
//// import sinal/fields
////
//// pub type RequestMetadata {
////   RequestMetadata(route: String, correlation: Option(Correlation))
//// }
////
//// pub fn request_metadata() -> fields.Fields(RequestMetadata) {
////   fields.record({
////     use route <- fields.parameter
////     use correlation <- fields.parameter
////     RequestMetadata(route:, correlation:)
////   })
////   |> fields.and(fields.string("route"), fn(m: RequestMetadata) { m.route })
////   |> fields.and(correlation.field(), fn(m) { m.correlation })
////   |> fields.build
//// }
//// ```
////
//// ## Propagation
////
//// A package with work-scoped events puts `correlation: Option(Correlation)`
//// in their metadata. It accepts the value where the work starts, copies it
//// into every event of that work, including events from helper processes,
//// and passes it to every package it calls on the caller's behalf. A span
//// carries it in its start and stop metadata.
////
//// A correlation identifies one unit of work, so it has unbounded
//// cardinality: never use it as a metric tag.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/int
import gleam/option.{type Option}
import gleam/string
import sinal/fields

/// The largest correlation, in bytes.
pub const max_bytes = 128

/// A correlation value: a UTF-8 string of 1 to `max_bytes` bytes.
pub opaque type Correlation {
  Correlation(value: String)
}

/// Why `from_string` refused a value. The union is closed.
pub type CorrelationError {
  /// The value was empty.
  EmptyCorrelation
  /// The value had `bytes` bytes, more than `max_bytes`.
  CorrelationTooLong(bytes: Int, max_bytes: Int)
}

/// Accepts `value` as a correlation when it has 1 to 128 bytes.
pub fn from_string(value: String) -> Result(Correlation, CorrelationError) {
  let bytes = string.byte_size(value)
  case bytes {
    0 -> Error(EmptyCorrelation)
    _ if bytes > max_bytes -> Error(CorrelationTooLong(bytes:, max_bytes:))
    _ -> Ok(Correlation(value))
  }
}

/// A fresh correlation: 128 random bits as 32 lowercase hexadecimal
/// characters, the shape of a W3C trace id. Values are unique across nodes.
pub fn unique() -> Correlation {
  Correlation(unique_value())
}

@external(erlang, "sinal_ffi", "unique_correlation")
fn unique_value() -> String

/// The correlation's text.
pub fn to_string(correlation: Correlation) -> String {
  correlation.value
}

/// The `correlation` metadata field. `None` omits the key; a missing key,
/// or the atom `nil` or `undefined`, decodes as `None`. A value that is not
/// a binary of 1 to 128 bytes fails to decode.
pub fn field() -> fields.Fields(Option(Correlation)) {
  fields.optional(fields.field(
    "correlation",
    fn(correlation: Correlation) { dynamic.string(correlation.value) },
    decode.string
      |> decode.then(fn(value) {
        case from_string(value) {
          Ok(correlation) -> decode.success(correlation)
          Error(_) ->
            decode.failure(
              Correlation(value),
              "a correlation of 1 to " <> int.to_string(max_bytes) <> " bytes",
            )
        }
      }),
  ))
}

/// Describes a refusal for logs.
pub fn describe_error(error: CorrelationError) -> String {
  case error {
    EmptyCorrelation -> "the correlation is empty"
    CorrelationTooLong(bytes:, max_bytes:) ->
      "the correlation has "
      <> int.to_string(bytes)
      <> " bytes, more than "
      <> int.to_string(max_bytes)
  }
}

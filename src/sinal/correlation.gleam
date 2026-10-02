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
//// The key `correlation` holds a UTF-8 binary. Two codecs share that key and
//// wire encoding; choose by whether the event always has a correlation.
////
//// - `field()` is `Fields(Option(Correlation))`, omitted when there is none.
////   A library uses it, because a correlation is present only when the
////   caller supplied one.
//// - `required_field()` is `Fields(Correlation)`. An application event that
////   always carries one uses it, so the metadata holds a plain
////   `Correlation`.
////
//// A handler using `field()` reads events emitted with `required_field()`
//// as `Some(correlation)`, so a library handler needs no change. An Erlang
//// or Elixir handler reads `metadata.correlation` without knowing which
//// package emitted the event or which codec wrote it.
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
////   use route <- fields.include(fields.string("route"), get: fn(m) { m.route })
////   use correlation <- fields.include(correlation.field(), get: fn(m) {
////     m.correlation
////   })
////   fields.success(RequestMetadata(route:, correlation:))
//// }
//// ```
////
//// An application event that always has one declares
//// `correlation: Correlation` and `correlation.required_field()` instead.
////
//// ## Propagation
////
//// A library with work-scoped events puts `correlation: Option(Correlation)`
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
///
/// An application id can be longer, for example one joined from publisher
/// input. Derive a stable value that fits instead of dropping the
/// correlation: the lowercase hexadecimal SHA-256 digest of the id (64
/// characters, from `gleam_crypto`'s `crypto.hash(crypto.Sha256, ..)`)
/// maps the same id to the same correlation.
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

/// The `correlation` metadata field for an event that may have none: a
/// library carries `Option(Correlation)` because the caller may not have
/// supplied one. `None` omits the key; a missing key, or the atom `nil` or
/// `undefined`, decodes as `None`. A value that is not a binary of 1 to 128
/// bytes fails to decode.
///
/// An application event that always has a correlation uses
/// `required_field` instead. Both use the key `correlation` and the same
/// wire encoding, so a handler that reads `field()` sees the events emitted
/// with `required_field()` as `Some(correlation)`.
pub fn field() -> fields.Fields(Option(Correlation)) {
  fields.optional(required_field())
}

/// The `correlation` metadata field for an event that always has one, such
/// as an application's own event: the metadata holds a `Correlation`, with
/// no `Some(..)` on emit and no unreachable `None` on read.
///
/// It uses the same key (`correlation`) and wire encoding as `field()`, so a
/// handler written with `field()`, such as a library's, reads these events
/// as `Some(correlation)`. Decoding fails like any other field when the key
/// is missing, or when the value is not a binary of 1 to 128 bytes; the atom
/// `nil` is not a correlation. A handler that cannot decode the metadata
/// skips that one call, reports `MalformedMetadata` and stays attached.
///
/// ```gleam
/// pub type TicketMetadata {
///   TicketMetadata(ticket: Correlation, queue: String)
/// }
///
/// pub fn ticket_metadata() -> fields.Fields(TicketMetadata) {
///   use ticket <- fields.include(correlation.required_field(), get: fn(m) {
///     m.ticket
///   })
///   use queue <- fields.include(fields.string("queue"), get: fn(m) { m.queue })
///   fields.success(TicketMetadata(ticket:, queue:))
/// }
/// ```
pub fn required_field() -> fields.Fields(Correlation) {
  fields.field(
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
  )
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

//// Sinal's own diagnostics: conditions that sinal detects on an emit or
//// handler path and reports without failing the emitter.
////
//// Two conditions are reported, each per event name:
////
//// - `UnlistedValue`: an emit path encoded a value that its `fields.enum`
////   list does not name. The event is still emitted.
//// - `SkippedInvocation`: an `observe` or `subscription` handler skipped
////   one invocation because a native map did not decode.
////
//// A faulty definition or a foreign producer can repeat either condition
//// on every event, so reporting is coalesced. The first occurrence of a
//// condition for an event name logs one warning in the `[sinal]` logger
//// domain. Every occurrence is counted, and the `[sinal, diagnostic,
//// occurred]` event (`sinal.diagnostic_event`) is emitted when the count
//// for that condition and event name reaches 1, 2, 4, 8 and each later
//// power of two.
////
//// ## Limits
////
//// - **Reports thin out.** A condition repeated a million times produces
////   one warning and twenty-one events. Occurrences after the last power
////   of two stay counted and are reported with the next one.
//// - **Counts last for the life of the node** and are kept per condition
////   and event name, not per handler. A warning is never logged twice for
////   one condition and event name.
//// - **The report runs in the process that hit the condition** (the
////   emitter, or the forwarder for a routed event's handler), is
////   synchronous, and is never routed through a forwarder.

import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/list
import gleam/string
import sinal/fields.{type Fields}
import sinal/internal/ffi

/// The condition a report counts. The union is closed.
pub type Kind {
  /// An emit path encoded a value missing from its `fields.enum` list.
  UnlistedValue
  /// An `observe` or `subscription` handler skipped one invocation.
  SkippedInvocation
}

/// Measurements of `sinal.diagnostic_event`. Read it by label; sinal may
/// add fields.
///
/// - `occurrences`: occurrences since the previous report of this
///   condition for this event name, this one included.
/// - `total`: occurrences since the node started.
pub type Count {
  Count(occurrences: Int, total: Int)
}

/// Metadata of `sinal.diagnostic_event`. Read it by label; sinal may add
/// fields.
///
/// - `event`: the name of the event the condition concerns, joined with
///   dots, for example `"http_gun.request.stop"`.
/// - `detail`: a description of the occurrence that triggered the report,
///   for logs.
pub type Report {
  Report(kind: Kind, event: String, detail: String)
}

/// The name of `sinal.diagnostic_event`.
pub const event_name = ["sinal", "diagnostic", "occurred"]

/// The measurement codec of `sinal.diagnostic_event`: the integer keys
/// `occurrences` and `total`.
pub fn count_fields() -> Fields(Count) {
  use occurrences <- fields.include(
    fields.int("occurrences"),
    get: fn(c: Count) { c.occurrences },
  )
  use total <- fields.include(fields.int("total"), get: fn(c: Count) { c.total })
  fields.success(Count(occurrences:, total:))
}

/// The metadata codec of `sinal.diagnostic_event`: `kind`
/// (`unlisted_value` or `skipped_invocation`), `event` and `detail`.
pub fn report_fields() -> Fields(Report) {
  use kind <- fields.include(
    fields.enum("kind", [UnlistedValue, SkippedInvocation], fn(kind) {
      case kind {
        UnlistedValue -> "unlisted_value"
        SkippedInvocation -> "skipped_invocation"
      }
    }),
    get: fn(r: Report) { r.kind },
  )
  use event <- fields.include(fields.string("event"), get: fn(r: Report) {
    r.event
  })
  use detail <- fields.include(fields.string("detail"), get: fn(r: Report) {
    r.detail
  })
  fields.success(Report(kind:, event:, detail:))
}

@external(erlang, "sinal_ffi", "count_diagnostic")
fn count(kind: Kind, name: List(Atom)) -> Int

/// Counts one occurrence of `kind` for the event `name`. On the first it
/// logs `describe()` as a warning; on the first and at every later power
/// of two it emits the diagnostic event. `describe` runs only then.
@internal
pub fn report(
  kind: Kind,
  name name: List(Atom),
  describe describe: fn() -> String,
) -> Nil {
  let total = count(kind, name)
  case int.bitwise_and(total, total - 1) == 0 {
    False -> Nil
    True -> {
      let detail = describe()
      case total {
        1 ->
          ffi.log_warning(
            detail
            <> ". Later occurrences are counted and reported by the [sinal, diagnostic, occurred] event",
          )
        _ -> Nil
      }
      // Emitted directly, never through a route, so reporting cannot be
      // dropped or reordered by a forwarder.
      ffi.telemetry_execute(
        list.map(event_name, atom.create),
        fields.encode(
          count_fields(),
          Count(occurrences: total - total / 2, total:),
        ),
        fields.encode(
          report_fields(),
          Report(
            kind:,
            event: string.join(list.map(name, atom.to_string), "."),
            detail:,
          ),
        ),
      )
    }
  }
}

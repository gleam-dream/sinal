//// Sinal's own diagnostics: conditions that sinal detects on an emit or
//// handler path and reports without failing the emitter.
////
//// Two conditions are counted, each per event name:
////
//// - `UnlistedValue`: an emit path encoded a value that its `fields.enum`
////   list does not name. The event is still emitted.
//// - `SkippedInvocation`: an `observe` or `subscription` handler skipped
////   one invocation because a native map did not decode.
////
//// A faulty definition or a foreign producer can repeat either condition
//// on every event, so sinal logs one warning, in the `[sinal]` logger
//// domain, on the first occurrence of a condition for an event name, and
//// only counts the later ones. `sinal.diagnostics` reads the exact totals
//// at any time; an application polls it into whatever reporter it uses.
////
//// ## Limits
////
//// - **Counts last for the life of the node** and are kept per condition
////   and event name, not per handler. Reading does not reset them, so a
////   reporter that wants a rate subtracts its previous reading.
//// - **A warning is never logged twice** for one condition and event name.
//// - **The warning is logged in the process that met the condition** (the
////   emitter, or the forwarder for a routed event's handler). Later
////   occurrences cost one atomic increment and build no message.

import gleam/erlang/atom.{type Atom}
import gleam/list
import sinal/internal/ffi

/// The condition a diagnostic counts. The union is closed.
pub type Kind {
  /// An emit path encoded a value missing from its `fields.enum` list.
  UnlistedValue
  /// An `observe` or `subscription` handler skipped one invocation.
  SkippedInvocation
}

/// The exact number of times one condition occurred for one event since
/// the node started. `event` is the event name, as `sinal.name` returns it.
pub type Diagnostic {
  Diagnostic(kind: Kind, event: List(String), total: Int)
}

@external(erlang, "sinal_ffi", "count_diagnostic")
fn count(kind: Kind, name: List(Atom)) -> Int

@external(erlang, "sinal_ffi", "diagnostics")
fn counters() -> List(#(Kind, List(Atom), Int))

/// Every condition that occurred at least once, with its total, ordered by
/// event name and then condition.
@internal
pub fn all() -> List(Diagnostic) {
  counters()
  |> list.map(fn(entry) {
    let #(kind, name, total) = entry
    Diagnostic(kind:, event: list.map(name, atom.to_string), total:)
  })
}

/// Counts one occurrence of `kind` for the event `name`. On the first it
/// logs `describe()` as a warning; `describe` runs only then.
@internal
pub fn report(
  kind: Kind,
  name name: List(Atom),
  describe describe: fn() -> String,
) -> Nil {
  case count(kind, name) {
    1 ->
      ffi.log_warning(
        describe()
        <> ". Later occurrences are counted; sinal.diagnostics() reads the total",
      )
    _ -> Nil
  }
}

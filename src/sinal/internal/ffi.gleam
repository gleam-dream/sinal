import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}

@external(erlang, "sinal_ffi", "identity")
pub fn to_dynamic(value: a) -> Dynamic

/// True while this process runs `decoding`.
@external(erlang, "sinal_ffi", "is_decoding")
pub fn is_decoding() -> Bool

/// Runs `decode` with `is_decoding` true, and restores it afterwards.
@external(erlang, "sinal_ffi", "decoding")
pub fn decoding(decode: fn() -> a) -> a

@external(erlang, "sinal_ffi", "empty_map")
pub fn empty_map() -> Dynamic

@external(erlang, "sinal_ffi", "map_put")
pub fn map_put(map: Dynamic, key: Atom, value: Dynamic) -> Dynamic

pub type Lookup {
  NotAMap
  Absent
  Present(Dynamic)
}

@external(erlang, "sinal_ffi", "map_lookup")
pub fn map_lookup(map: Dynamic, key: Atom) -> Lookup

@external(erlang, "sinal_ffi", "is_native_map")
pub fn is_map(term: Dynamic) -> Bool

/// True for the native BEAM markers a foreign producer may use in place of
/// omitting an optional field: the atoms `nil` and `undefined`.
@external(erlang, "sinal_ffi", "is_missing_marker")
pub fn is_missing_marker(term: Dynamic) -> Bool

/// Attaches `callback` under `handler_id` through `fun sinal_ffi:handle/4`,
/// starting the `telemetry` application first when it is not running.
/// Returns `Error(Nil)` when the id is already attached.
@external(erlang, "sinal_ffi", "telemetry_attach_many")
pub fn telemetry_attach_many(
  handler_id: Dynamic,
  event_names: List(List(Atom)),
  callback: fn(List(Atom), Dynamic, Dynamic) -> Nil,
) -> Result(Nil, Nil)

/// Detaches `handler_id`. Returns `Error(Nil)` when it is not attached,
/// including when the `telemetry` application is not running.
@external(erlang, "sinal_ffi", "telemetry_detach")
pub fn telemetry_detach(handler_id: Dynamic) -> Result(Nil, Nil)

@external(erlang, "sinal_ffi", "telemetry_execute")
pub fn telemetry_execute(
  event_name: List(Atom),
  measurements: Dynamic,
  metadata: Dynamic,
) -> Nil

@external(erlang, "sinal_ffi", "raise_callback_failure")
pub fn raise_callback_failure(reason: String) -> a

@external(erlang, "sinal_ffi", "telemetry_span")
pub fn telemetry_span(
  event_prefix: List(Atom),
  start_metadata: Dynamic,
  span_fun: fn() -> #(a, Dynamic, Dynamic),
) -> a

/// A handler id no other sinal registration uses: `{sinal_handler, N}`.
@external(erlang, "sinal_ffi", "unique_handler_id")
pub fn unique_handler_id() -> Dynamic

/// A handler id no other sinal registration uses, naming `label`:
/// `{sinal_handler, Label, N}`.
@external(erlang, "sinal_ffi", "labelled_handler_id")
pub fn labelled_handler_id(label: String) -> Dynamic

/// Logs `message` at warning level from the calling process, in the
/// `[sinal]` logger domain.
@external(erlang, "sinal_ffi", "log_warning")
pub fn log_warning(message: String) -> Nil

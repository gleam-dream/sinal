import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}

@external(erlang, "sinal_ffi", "identity")
pub fn to_dynamic(value: a) -> Dynamic

@external(erlang, "sinal_ffi", "empty_map")
pub fn empty_map() -> Dynamic

@external(erlang, "sinal_ffi", "map_from_pair")
pub fn map_from_pair(key: Atom, value: Dynamic) -> Dynamic

@external(erlang, "sinal_ffi", "map_get")
pub fn map_get(map: Dynamic, key: Atom) -> Result(Dynamic, Nil)

@external(erlang, "sinal_ffi", "map_merge")
pub fn map_merge(map_a: Dynamic, map_b: Dynamic) -> Dynamic

@external(erlang, "sinal_ffi", "is_native_map")
pub fn is_map(term: Dynamic) -> Bool

pub type NativeAttachError {
  NativeAlreadyExists
  NativeAttachOther(Dynamic)
}

pub type NativeDetachError {
  NativeNotFound
  NativeDetachOther(Dynamic)
}

@external(erlang, "sinal_ffi", "telemetry_attach_many")
pub fn telemetry_attach_many(
  handler_id: Dynamic,
  event_names: List(List(Atom)),
  callback: fn(List(Atom), Dynamic, Dynamic, Dynamic) -> Nil,
  config: Dynamic,
) -> Result(Nil, NativeAttachError)

@external(erlang, "sinal_ffi", "telemetry_detach")
pub fn telemetry_detach(handler_id: Dynamic) -> Result(Nil, NativeDetachError)

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

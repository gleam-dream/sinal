import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}

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

@external(erlang, "telemetry", "execute")
pub fn telemetry_execute(
  event_name: List(Atom),
  measurements: Dynamic,
  metadata: Dynamic,
) -> Nil

@external(erlang, "telemetry", "detach")
pub fn telemetry_detach(handler_id: Dynamic) -> Result(Nil, Dynamic)

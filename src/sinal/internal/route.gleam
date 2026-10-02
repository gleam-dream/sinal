//// The node's forwarder routes: event-name prefixes mapped to the function
//// that hands an encoded event to a forwarder. `sinal.emit` reads them;
//// `sinal/forwarder` writes them.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}

pub type Send =
  fn(List(Atom), Dynamic, Dynamic) -> Nil

@external(erlang, "sinal_forwarder_ffi", "put_route")
pub fn put(prefix: List(Atom), send: Send) -> Nil

@external(erlang, "sinal_forwarder_ffi", "erase_route")
pub fn erase(prefix: List(Atom)) -> Nil

/// The send function of the longest routed prefix of `name`.
@external(erlang, "sinal_forwarder_ffi", "find_route")
pub fn find(name: List(Atom)) -> Result(Send, Nil)

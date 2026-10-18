//// Run every usage example once and print its name.
////
//// `gleam run` from this directory fails loudly if any example no longer
//// matches the library.

import gleam/io
import usage/correlation_ids
import usage/forwarding
import usage/handlers
import usage/observe
import usage/records
import usage/scopes
import usage/spans

pub fn main() -> Nil {
  io.println("observe")
  observe.run()
  io.println("records")
  records.run()
  io.println("handlers")
  handlers.run()
  io.println("scopes")
  scopes.run()
  io.println("spans")
  spans.run()
  io.println("forwarding")
  forwarding.run()
  io.println("correlation_ids")
  correlation_ids.run()
  io.println("all usage examples passed")
}

//// Define an event, observe it, emit a value and detach the handler.

import gleam/erlang/process
import sinal
import sinal/fields

// snips-start: observe-request
pub fn observe_request_example() {
  let finished =
    sinal.event(
      ["request", "finished"],
      fields.int("duration_ms"),
      fields.string("route"),
    )
  let attachment =
    sinal.observe(finished, fn(_duration_ms, _route) {
      // Runs in the emitting process, before `emit` returns.
      Nil
    })
  sinal.emit(finished, 42, "/users")
  let assert Ok(Nil) = sinal.detach(attachment)
}

// snips-end: observe-request

/// Run the example and check that the handler saw the emitted values in the
/// emitting process.
pub fn run() -> Nil {
  let assert Ok(Nil) = observe_request_example()

  let event =
    sinal.event(["usage", "observe"], fields.int("n"), fields.string("route"))
  let seen = process.new_subject()
  let attachment =
    sinal.observe(event, fn(n, route) {
      process.send(seen, #(n, route, process.self()))
    })
  sinal.emit(event, 7, "/users")
  assert process.receive(seen, 0) == Ok(#(7, "/users", process.self()))
  let assert Ok(Nil) = sinal.detach(attachment)
  // A second detach reports that nothing was attached.
  assert sinal.detach(attachment) == Error(Nil)
}

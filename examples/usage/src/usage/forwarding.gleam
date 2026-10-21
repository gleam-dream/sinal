//// Move handler execution into a supervised forwarder, either by routing an
//// event-name prefix to it or by emitting to a forwarder a package owns.

import gleam/erlang/process
import gleam/otp/static_supervisor
import sinal
import sinal/fields
import sinal/forwarder

// snips-start: forward-library
pub fn isolate_library(name: process.Name(forwarder.Message)) -> Nil {
  let observations = forwarder.new(name)
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(forwarder.supervised(observations))
    |> static_supervisor.start
  // Every `sinal.emit` of an event named `my_library..` now returns as soon
  // as the event is handed to the forwarder.
  forwarder.route(["my_library"], observations)
}

// snips-end: forward-library

pub fn emit_owned(
  observations: forwarder.Forwarder,
  event: sinal.Event(Int, Nil),
) -> Nil {
  case forwarder.emit(observations, event, 1, Nil) {
    Ok(Nil) -> Nil
    // Dropped and counted in the forwarder's `dropped_event`.
    Error(forwarder.CapacityExceeded) -> Nil
    Error(forwarder.ForwarderUnavailable) -> Nil
  }
}

/// Route a prefix and check that handlers move out of the emitting process,
/// then do the same through an owned forwarder.
pub fn run() -> Nil {
  let event =
    sinal.event(["my_library", "request"], fields.int("n"), fields.empty())
  let seen = process.new_subject()
  let attachment =
    sinal.observe(event, fn(n, _) { process.send(seen, #(n, process.self())) })

  sinal.emit(event, 1, Nil)
  assert process.receive(seen, 0) == Ok(#(1, process.self()))

  isolate_library(process.new_name("usage_library_forwarder"))
  sinal.emit(event, 2, Nil)
  let assert Ok(#(2, pid)) = process.receive(seen, 500)
  assert pid != process.self()
  forwarder.unroute(["my_library"])
  let assert Ok(Nil) = sinal.detach(attachment)

  let owned = sinal.event(["usage", "owned"], fields.int("n"), fields.empty())
  let observations =
    forwarder.new(process.new_name("usage_owned_forwarder"))
    |> forwarder.with_capacity(8)
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(forwarder.supervised(observations))
    |> static_supervisor.start
  let owned_seen = process.new_subject()
  let owned_attachment =
    sinal.observe(owned, fn(n, _) { process.send(owned_seen, n) })
  emit_owned(observations, owned)
  assert process.receive(owned_seen, 500) == Ok(1)
  let assert Ok(Nil) = sinal.detach(owned_attachment)
  Nil
}

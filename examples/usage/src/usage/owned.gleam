//// A handler belongs to the process that attaches it and is detached when
//// that process exits. A handler meant to live as long as the application
//// is attached by a long-lived process: here, an actor that attaches it
//// while it starts, so a supervisor that restarts the actor also restarts
//// the handler, and the old handler is detached with the old actor.

import gleam/erlang/process
import gleam/otp/actor
import sinal
import sinal/fields

pub type Message {
  Count(reply: process.Subject(Int))
  Seen
}

// snips-start: owned-handler
pub fn start_request_counter(
  finished: sinal.Event(Int, String),
) -> Result(actor.Started(process.Subject(Message)), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    // The actor's process owns the handler.
    let _attachment =
      sinal.observe(finished, fn(_duration_ms, _route) {
        process.send(subject, Seen)
      })
    actor.initialised(0)
    |> actor.returning(subject)
    |> Ok
  })
  |> actor.on_message(fn(count, message) {
    case message {
      Seen -> actor.continue(count + 1)
      Count(reply) -> {
        process.send(reply, count)
        actor.continue(count)
      }
    }
  })
  |> actor.start
}

// snips-end: owned-handler

/// Start the counter, emit twice and read the count back.
pub fn run() -> Nil {
  let finished =
    sinal.event(
      ["usage", "owned", "finished"],
      fields.int("duration_ms"),
      fields.string("route"),
    )
  let assert Ok(counter) = start_request_counter(finished)
  sinal.emit(finished, 1, "/users")
  sinal.emit(finished, 2, "/users")
  assert process.call(counter.data, 1000, Count) == 2
}

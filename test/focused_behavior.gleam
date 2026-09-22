import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import sinal
import sinal/fields

pub type DeliveryReport {
  DeliveryReport(
    selected_event_name: List(String),
    count: Int,
    user: String,
    emitter_pid: process.Pid,
  )
}

pub fn main() {
  let assert Ok(handler_id) = sinal.handler_id("focused-handler-1")

  let event_part_1 = atom.create("sinal")
  let event_part_2 = atom.create("test")
  let event_part_3 = atom.create("event")
  let count_atom = atom.create("count")
  let user_atom = atom.create("user")

  let count_field =
    fields.field(count_atom, fn(n: Int) { Ok(dynamic.int(n)) }, fn(dyn) {
      case decode.run(dyn, decode.int) {
        Ok(n) -> Ok(n)
        Error(_) -> Error(fields.FieldDecodeError("expected int"))
      }
    })

  let user_field =
    fields.field(user_atom, fn(s: String) { Ok(dynamic.string(s)) }, fn(dyn) {
      case decode.run(dyn, decode.string) {
        Ok(s) -> Ok(s)
        Error(_) -> Error(fields.FieldDecodeError("expected string"))
      }
    })

  let assert Ok(event) =
    sinal.event(
      [event_part_1, event_part_2, event_part_3],
      count_field,
      user_field,
    )

  let current_pid = process.self()
  let subject = process.new_subject()

  let handler = fn(selected_event, count: Int, user: String) {
    let executing_pid = process.self()
    process.send(
      subject,
      DeliveryReport(
        selected_event_name: sinal.event_name(selected_event),
        count: count,
        user: user,
        emitter_pid: executing_pid,
      ),
    )
    Ok(Nil)
  }

  let on_failure = fn(_ev, _failure) { Nil }

  // Step 1: Attach typed handler to trusted event.
  // Intentional stop point: reaches todo as "native telemetry attach is not yet implemented"
  let assert Ok(attachment) =
    sinal.attach(handler_id, event, handler, on_failure)

  // Step 2: Emit event synchronously from current process.
  let assert Ok(Nil) = sinal.emit(event, 42, "alice")

  // Step 3: Assert observed delivery synchronously in emitter process with exact decoded values
  let assert Ok(report) = process.receive(subject, 0)

  let assert True = report.selected_event_name == ["sinal", "test", "event"]
  let assert True = report.count == 42
  let assert True = report.user == "alice"
  // Proves the callback ran synchronously in the emitting process
  let assert True = report.emitter_pid == current_pid

  // Detach cleanly
  let assert Ok(Nil) = sinal.detach(attachment)
}

import gleam/dynamic
import gleam/dynamic/decode
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
  let count_field = fields.field("count", dynamic.int, decode.int)
  let user_field = fields.field("user", dynamic.string, decode.string)
  let event = sinal.event(["sinal", "test", "event"], count_field, user_field)

  let current_pid = process.self()
  let subject = process.new_subject()

  let handler = fn(selected_event, count: Int, user: String) {
    process.send(
      subject,
      DeliveryReport(
        selected_event_name: sinal.name(selected_event),
        count: count,
        user: user,
        emitter_pid: process.self(),
      ),
    )
    Ok(Nil)
  }

  let assert Ok(attachment) =
    sinal.attach(sinal.handler([event], handler, fn(_ev, _failure) { Nil }))

  sinal.emit(event, 42, "alice")

  // Synchronous delivery puts the decoded result in the mailbox before
  // emit returns, so a zero-timeout receive must find it.
  let assert Ok(report) = process.receive(subject, 0)
  let assert True = report.selected_event_name == ["sinal", "test", "event"]
  let assert True = report.count == 42
  let assert True = report.user == "alice"
  let assert True = report.emitter_pid == current_pid

  let assert Ok(Nil) = sinal.detach(attachment)
}

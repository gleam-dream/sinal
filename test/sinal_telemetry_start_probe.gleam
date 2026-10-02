//// Runs inside a peer VM started by `sinal_telemetry_start_test`, where the
//// `telemetry` application is not running.

import gleam/erlang/process
import sinal
import sinal/fields

@external(erlang, "sinal_telemetry_start_ffi", "telemetry_running")
fn telemetry_running() -> Bool

@external(erlang, "sinal_telemetry_start_ffi", "stop_telemetry")
fn stop_telemetry() -> Nil

pub type Report {
  Report(
    running_at_start: Bool,
    emit_without_telemetry: Bool,
    observed: Result(Int, Nil),
    running_after_observe: Bool,
    detach_after_stop: Result(Nil, Nil),
    scoped: Result(Int, Nil),
    running_after_scope: Bool,
  )
}

pub fn run() -> Report {
  let event =
    sinal.event(["telemetry_start_probe", "e"], fields.int("n"), fields.empty())
  let running_at_start = telemetry_running()

  // Without the application, an emit reaches no handler and does not crash.
  sinal.emit(event, 0, Nil)
  let emit_without_telemetry = True

  // `observe` starts the application instead of exiting with `noproc`.
  let seen = process.new_subject()
  let attachment = sinal.observe(event, fn(n, _) { process.send(seen, n) })
  sinal.emit(event, 1, Nil)
  let observed = process.receive(seen, 1000)
  let running_after_observe = telemetry_running()

  // Stopping the application removes every handler; `detach` then reports
  // the handler as not attached instead of exiting with `noproc`.
  stop_telemetry()
  let detach_after_stop = sinal.detach(attachment)

  // `with_subscriptions` (through `attach`) starts it again.
  let scoped = case
    sinal.with_subscriptions(
      sinal.subscriptions([
        sinal.subscription(event, fn(n, _) { process.send(seen, n) }),
      ]),
      fn() {
        sinal.emit(event, 2, Nil)
        process.receive(seen, 1000)
      },
    )
  {
    Ok(completion) -> completion.work_result
    Error(_) -> Error(Nil)
  }

  Report(
    running_at_start:,
    emit_without_telemetry:,
    observed:,
    running_after_observe:,
    detach_after_stop:,
    scoped:,
    running_after_scope: telemetry_running(),
  )
}

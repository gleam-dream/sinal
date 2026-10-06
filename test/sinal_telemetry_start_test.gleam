import gleeunit/should
import sinal_telemetry_start_probe.{Report}

@external(erlang, "sinal_telemetry_start_ffi", "run_in_fresh_vm")
fn run_in_fresh_vm() -> sinal_telemetry_start_probe.Report

// The fresh VM starts without telemetry. The first attachment must start
// its application, and a later scope must restart it after a stop.
pub fn attach_starts_the_telemetry_application_test() {
  run_in_fresh_vm()
  |> should.equal(Report(
    running_at_start: False,
    emit_without_telemetry: True,
    observed: Ok(1),
    running_after_observe: True,
    detach_after_stop: Error(Nil),
    scoped: Ok(2),
    running_after_scope: True,
  ))
}

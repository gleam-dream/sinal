//// Sinal's OTP application callback. The application supervises the
//// janitor that binds handler registrations to their owners, so every
//// registration has a janitor without the caller starting one.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/otp/actor
import gleam/otp/static_supervisor as supervisor
import sinal/internal/janitor

pub fn start(
  _type: Dynamic,
  _arguments: Dynamic,
) -> Result(Pid, actor.StartError) {
  case
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(janitor.supervised())
    |> supervisor.start
  {
    Ok(started) -> Ok(started.pid)
    Error(error) -> Error(error)
  }
}

pub fn stop(_state: Dynamic) -> Nil {
  Nil
}

//// The janitor: one process of sinal's own OTP application that binds
//// every handler registration to the process that made it, and detaches
//// the registration when that process exits for any reason.
////
//// `sinal.attach` asks the janitor to install the handler for the calling
//// process (the owner). The janitor installs it and monitors the owner. On
//// the owner's `DOWN` it reads the native handler table and detaches every
//// handler whose config names that owner. `sinal.detach` also runs in the
//// janitor, so installation, detach and owner cleanup are serialized.
////
//// The janitor keeps no record of handlers, only one monitor per owner.
//// Each handler carries its owner and a token that names its registration
//// in its native config (`{sinal_owner, Owner, Token, Callback}`), so the
//// native handler table, which the longer-lived `telemetry` application
//// owns, is the one record. A restarted janitor reads the owners back from
//// it and monitors them again; the owners that exited while no janitor ran
//// deliver their `DOWN` at once.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision
import sinal/internal/ffi.{type Token}

/// The janitor's messages.
pub opaque type Message {
  Attach(
    owner: Pid,
    id: Dynamic,
    token: Token,
    install: fn() -> Result(Nil, Nil),
    reply: process.Subject(Installation),
  )
  Detach(id: Dynamic, token: Token, reply: process.Subject(Result(Nil, Nil)))
  OwnerDown(process.Down)
}

type Exception

type Captured(a) {
  Returned(a)
  Raised(Exception)
}

type Installation {
  Installed
  Refused
  InstallRaised(Exception)
}

/// The owners the janitor monitors, each with its monitor.
type State {
  State(owners: Dict(Pid, process.Monitor))
}

@external(erlang, "sinal_janitor_ffi", "capture")
fn capture(work: fn() -> a) -> Captured(a)

@external(erlang, "sinal_janitor_ffi", "reraise")
fn reraise(exception: Exception) -> a

@external(erlang, "sinal_janitor_ffi", "name")
fn name() -> process.Name(Message)

@external(erlang, "sinal_janitor_ffi", "send")
fn send(janitor: Pid, message: Message) -> Nil

@external(erlang, "sinal_janitor_ffi", "owners")
fn owners() -> List(Pid)

@external(erlang, "sinal_janitor_ffi", "handlers_of")
fn handlers_of(owner: Pid) -> List(#(Dynamic, Token))

@external(erlang, "sinal_janitor_ffi", "holder")
fn holder(id: Dynamic) -> Result(#(Pid, Token), Nil)

/// Detaches registration `token` under `id`, and nothing else.
@external(erlang, "sinal_janitor_ffi", "detach_registration")
fn detach_registration(id: Dynamic, token: Token) -> Result(Nil, Nil)

@external(erlang, "sinal_janitor_ffi", "await_restart")
fn await_restart() -> Nil

/// How long the janitor may take to start.
const init_timeout = 5000

/// How many times a request waits for a janitor that is being restarted
/// before it gives up.
const restart_attempts = 100

/// The janitor's child specification, for sinal's application supervisor.
pub fn supervised() -> supervision.ChildSpecification(Nil) {
  supervision.worker(start)
}

fn start() -> Result(actor.Started(Nil), actor.StartError) {
  actor.new_with_initialiser(init_timeout, fn(subject) {
    // The actor registers its name before this runs. A registration made
    // from now on either reaches this incarnation as a message, or was
    // installed earlier and is in the table read here.
    let state = list.fold(owners(), State(dict.new()), watch)
    actor.initialised(state)
    |> actor.selecting(
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(OwnerDown),
    )
    |> Ok
  })
  |> actor.named(name())
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    Attach(owner:, id:, token: _, install:, reply:) -> {
      let #(state, installation) = install_for(state, owner, id, install)
      process.send(reply, installation)
      actor.continue(state)
    }
    Detach(id:, token:, reply:) -> {
      process.send(reply, detach_captured(id, token))
      actor.continue(state)
    }
    OwnerDown(process.ProcessDown(pid:, ..)) -> {
      // A detach that raises must not skip the others or stop the janitor.
      list.each(handlers_of(pid), fn(handler) {
        detach_captured(handler.0, handler.1)
      })
      actor.continue(State(owners: dict.delete(state.owners, pid)))
    }
    OwnerDown(process.PortDown(..)) -> actor.continue(state)
  }
}

fn detach_captured(id: Dynamic, token: Token) -> Result(Nil, Nil) {
  case capture(fn() { detach_registration(id, token) }) {
    Returned(detached) -> detached
    Raised(_) -> Error(Nil)
  }
}

fn install_for(
  state: State,
  owner: Pid,
  id: Dynamic,
  install: fn() -> Result(Nil, Nil),
) -> #(State, Installation) {
  case capture(install) {
    Returned(Ok(Nil)) -> #(watch(state, owner), Installed)
    Raised(exception) -> #(state, InstallRaised(exception))
    Returned(Error(Nil)) ->
      case holder(id) {
        // The id is held by an owner that exited and whose `DOWN` is still
        // in the mailbox, as when a supervisor restarts a process that
        // attaches under a stable `with_id` id. The new owner takes it
        // over; the old owner's `DOWN` finds no handler of its own there.
        Ok(#(holder, held)) ->
          case process.is_alive(holder) {
            True -> #(state, Refused)
            False -> {
              let _ = detach_captured(id, held)
              case capture(install) {
                Returned(Ok(Nil)) -> #(watch(state, owner), Installed)
                Returned(Error(Nil)) -> #(state, Refused)
                Raised(exception) -> #(state, InstallRaised(exception))
              }
            }
          }
        Error(Nil) -> #(state, Refused)
      }
  }
}

/// Monitors `owner` unless it is already monitored. Monitoring an owner
/// that already exited delivers its `DOWN` at once.
fn watch(state: State, owner: Pid) -> State {
  case dict.has_key(state.owners, owner) {
    True -> state
    False ->
      State(owners: dict.insert(state.owners, owner, process.monitor(owner)))
  }
}

/// Runs `install` in the janitor and, when it returns `Ok`, binds handler
/// `id` to `owner`: the janitor detaches it when `owner` exits. `install`
/// attaches the handler with `token` in its config and returns `Error(Nil)`
/// when the id is taken; an exception it raises is re-raised here.
///
/// Waits for the janitor's answer with no deadline: a request the janitor
/// can still apply never outlives the caller's decision, so a failed attach
/// leaves no handler. The janitor is a local supervised process, so either
/// its answer comes or it exits. When it exits first, the registration
/// `token` names is detached, if the janitor installed it, and the attach
/// panics.
///
/// Starts sinal's application when it is not running. Panics when the
/// janitor does not come back after a restart.
pub fn attach(
  owner owner: Pid,
  id id: Dynamic,
  token token: Token,
  install install: fn() -> Result(Nil, Nil),
) -> Result(Nil, Nil) {
  let janitor = await_running(restart_attempts)
  case request(janitor, Attach(owner:, id:, token:, install:, reply: _)) {
    Ok(Installed) -> Ok(Nil)
    Ok(Refused) -> Error(Nil)
    Ok(InstallRaised(exception)) -> reraise(exception)
    Error(Nil) -> {
      let _ = detach_registration(id, token)
      panic as "sinal: the janitor exited before answering an attach"
    }
  }
}

/// Detaches registration `token` under `id` through the janitor. Returns
/// `Error(Nil)` when `id` holds another registration or none. A detach
/// whose janitor exits before answering is asked again of its successor:
/// the token makes the request safe to repeat.
pub fn detach(id id: Dynamic, token token: Token) -> Result(Nil, Nil) {
  detach_attempt(id, token, restart_attempts)
}

fn detach_attempt(
  id: Dynamic,
  token: Token,
  attempts: Int,
) -> Result(Nil, Nil) {
  let janitor = await_running(restart_attempts)
  case request(janitor, Detach(id:, token:, reply: _)) {
    Ok(detached) -> detached
    Error(Nil) if attempts > 0 -> detach_attempt(id, token, attempts - 1)
    Error(Nil) -> panic as "sinal: the janitor keeps exiting"
  }
}

/// Sends a request to the janitor `janitor` and waits for its answer, or
/// returns `Error(Nil)` when that janitor exits first.
fn request(
  janitor: Pid,
  make: fn(process.Subject(a)) -> Message,
) -> Result(a, Nil) {
  let reply = process.new_subject()
  let monitor = process.monitor(janitor)
  send(janitor, make(reply))
  let answer =
    process.new_selector()
    |> process.select_map(reply, Ok)
    |> process.select_specific_monitor(monitor, fn(_) { Error(Nil) })
    |> process.selector_receive_forever
  process.demonitor_process(monitor)
  answer
}

fn await_running(attempts: Int) -> Pid {
  case process.named(name()) {
    Ok(janitor) -> janitor
    Error(Nil) if attempts > 0 -> {
      await_restart()
      await_running(attempts - 1)
    }
    Error(Nil) -> panic as "sinal: the janitor is not running"
  }
}

//// The janitor: one process of sinal's own OTP application that binds
//// every handler registration to the process that made it, and detaches
//// the registration when that process exits for any reason.
////
//// `sinal.attach` asks the janitor to install the handler for the calling
//// process (the owner). The janitor installs it, monitors the owner, and
//// on the owner's `DOWN` detaches every handler the owner still holds.
//// Installation and cleanup happen in this one process, so an owner's exit
//// is always handled after the installations it made.
////
//// The janitor keeps no record that a crash can lose. Each handler carries
//// its owner in its native config (`{sinal_owner, Owner, Callback}`), so
//// the native handler table, which the longer-lived `telemetry`
//// application owns, is the record. A restarted janitor reads the owners
//// back from it, monitors them again, and the owners that exited while no
//// janitor ran deliver their `DOWN` at once.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision
import gleam/set.{type Set}

/// The janitor's messages.
pub opaque type Message {
  Attach(
    owner: Pid,
    id: Dynamic,
    install: fn() -> Result(Nil, Nil),
    reply: process.Subject(Installation),
  )
  Release(owner: Pid, id: Dynamic)
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

/// `holders` maps each handler id to its owner; `owners` maps each owner to
/// its monitor and the ids it holds. Both describe the same registrations.
type State {
  State(holders: Dict(Dynamic, Pid), owners: Dict(Pid, Owned))
}

type Owned {
  Owned(monitor: process.Monitor, ids: Set(Dynamic))
}

@external(erlang, "sinal_janitor_ffi", "capture")
fn capture(work: fn() -> a) -> Captured(a)

@external(erlang, "sinal_janitor_ffi", "reraise")
fn reraise(exception: Exception) -> a

@external(erlang, "sinal_janitor_ffi", "name")
fn name() -> process.Name(Message)

@external(erlang, "sinal_janitor_ffi", "owned_handlers")
fn owned_handlers() -> List(#(Pid, Dynamic))

/// Detaches handler `id` only when its native config names `owner`.
@external(erlang, "sinal_janitor_ffi", "detach_held")
fn detach_held(id: Dynamic, owner: Pid) -> Result(Nil, Nil)

@external(erlang, "sinal_janitor_ffi", "await_restart")
fn await_restart() -> Nil

const call_timeout = 5000

/// How many times a registration waits for a janitor that is being
/// restarted before it gives up.
const restart_attempts = 100

/// The janitor's child specification, for sinal's application supervisor.
pub fn supervised() -> supervision.ChildSpecification(Nil) {
  supervision.worker(start)
}

fn start() -> Result(actor.Started(Nil), actor.StartError) {
  actor.new_with_initialiser(call_timeout, fn(subject) {
    // The actor registers its name before this runs. A registration made
    // from now on either reaches this incarnation as a message, or was
    // installed earlier and is in the table read here.
    let state =
      list.fold(
        owned_handlers(),
        State(dict.new(), dict.new()),
        fn(state, entry) { hold(state, entry.0, entry.1) },
      )
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
    Attach(owner:, id:, install:, reply:) -> {
      let #(state, installation) = install_for(state, owner, id, install)
      process.send(reply, installation)
      actor.continue(state)
    }
    Release(owner:, id:) ->
      case dict.get(state.holders, id) {
        Ok(holder) if holder == owner -> actor.continue(drop(state, id))
        _ -> actor.continue(state)
      }
    OwnerDown(process.ProcessDown(pid:, ..)) ->
      case dict.get(state.owners, pid) {
        Error(Nil) -> actor.continue(state)
        Ok(Owned(ids:, ..)) -> {
          let state =
            set.fold(ids, state, fn(state, id) {
              // A detach that raises must not skip the others or stop the
              // janitor. An id that telemetry removed and another caller
              // reused is left alone.
              let _ = capture(fn() { detach_held(id, pid) })
              State(..state, holders: dict.delete(state.holders, id))
            })
          actor.continue(State(..state, owners: dict.delete(state.owners, pid)))
        }
      }
    OwnerDown(process.PortDown(..)) -> actor.continue(state)
  }
}

fn install_for(
  state: State,
  owner: Pid,
  id: Dynamic,
  install: fn() -> Result(Nil, Nil),
) -> #(State, Installation) {
  case capture(install) {
    Returned(Ok(Nil)) -> #(hold(state, owner, id), Installed)
    Raised(exception) -> #(state, InstallRaised(exception))
    Returned(Error(Nil)) ->
      case dict.get(state.holders, id) {
        // The id is held by an owner that exited and whose `DOWN` is still
        // in the mailbox, as when a supervisor restarts a process that
        // attaches under a stable `with_id` id. The new owner takes it
        // over; the old owner's `DOWN` no longer names it.
        Ok(holder) ->
          case process.is_alive(holder) {
            True -> #(state, Refused)
            False -> {
              let _ = capture(fn() { detach_held(id, holder) })
              let state = drop(state, id)
              case capture(install) {
                Returned(Ok(Nil)) -> #(hold(state, owner, id), Installed)
                Returned(Error(Nil)) -> #(state, Refused)
                Raised(exception) -> #(state, InstallRaised(exception))
              }
            }
          }
        Error(Nil) -> #(state, Refused)
      }
  }
}

fn hold(state: State, owner: Pid, id: Dynamic) -> State {
  // An id held by another owner whose handler was removed without a
  // release (telemetry removes a failing handler) moves to the new owner.
  let state = drop(state, id)
  let owned = case dict.get(state.owners, owner) {
    Ok(owned) -> owned
    // Monitoring an owner that already exited delivers its `DOWN` at once.
    Error(Nil) -> Owned(monitor: process.monitor(owner), ids: set.new())
  }
  State(
    holders: dict.insert(state.holders, id, owner),
    owners: dict.insert(
      state.owners,
      owner,
      Owned(..owned, ids: set.insert(owned.ids, id)),
    ),
  )
}

fn drop(state: State, id: Dynamic) -> State {
  case dict.get(state.holders, id) {
    Error(Nil) -> state
    Ok(owner) -> {
      let holders = dict.delete(state.holders, id)
      case dict.get(state.owners, owner) {
        Error(Nil) -> State(..state, holders:)
        Ok(Owned(monitor:, ids:)) -> {
          let ids = set.delete(ids, id)
          case set.is_empty(ids) {
            True -> {
              process.demonitor_process(monitor)
              State(holders:, owners: dict.delete(state.owners, owner))
            }
            False ->
              State(
                holders:,
                owners: dict.insert(state.owners, owner, Owned(monitor:, ids:)),
              )
          }
        }
      }
    }
  }
}

/// Runs `install` in the janitor and, when it returns `Ok`, binds handler
/// `id` to `owner`: the janitor detaches it when `owner` exits, unless
/// `release` came first. `install` returns `Error(Nil)` when the id is
/// taken; an exception it raises is re-raised here.
///
/// Starts sinal's application when it is not running. Panics when the
/// janitor does not answer within five seconds, or does not come back
/// after a restart.
pub fn attach(
  owner owner: Pid,
  id id: Dynamic,
  install install: fn() -> Result(Nil, Nil),
) -> Result(Nil, Nil) {
  await_running(restart_attempts)
  let installation =
    process.call(process.named_subject(name()), call_timeout, Attach(
      owner,
      id,
      install,
      _,
    ))
  case installation {
    Installed -> Ok(Nil)
    Refused -> Error(Nil)
    InstallRaised(exception) -> reraise(exception)
  }
}

fn await_running(attempts: Int) -> Nil {
  case process.named(name()) {
    Ok(_) -> Nil
    Error(Nil) if attempts > 0 -> {
      await_restart()
      await_running(attempts - 1)
    }
    Error(Nil) -> panic as "sinal: the janitor is not running"
  }
}

/// Makes the janitor forget handler `id` of `owner`, after a `detach`.
/// Does nothing when the janitor is not running: its replacement reads
/// the handler table, where the handler no longer is.
pub fn release(owner owner: Pid, id id: Dynamic) -> Nil {
  case process.named(name()) {
    Ok(_) -> {
      let _ =
        capture(fn() {
          process.send(process.named_subject(name()), Release(owner:, id:))
        })
      Nil
    }
    Error(Nil) -> Nil
  }
}

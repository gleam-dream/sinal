//// A janitor: a supervised process that monitors the owners of handler
//// registrations and detaches a registration when its owner exits.
////
//// `sinal.attach` and `sinal.with_subscriptions` clean up in the calling
//// process, so cleanup runs only when that process gets to run it. An exit
//// signal that terminates the process (a linked process dying, a
//// supervisor shutdown, a `kill`) skips it, and the handlers stay
//// attached for the life of the node. A janitor closes that gap: it
//// installs the handler itself, monitors the owner, and detaches when the
//// owner's `DOWN` arrives, whatever the exit reason.
////
//// The application supervises one janitor and passes it to the code that
//// registers handlers:
////
//// ```gleam
//// import gleam/erlang/process
//// import gleam/otp/static_supervisor as supervisor
//// import sinal
//// import sinal/janitor
////
//// pub fn start(name: process.Name(janitor.Message)) {
////   let cleaner = janitor.new(name)
////   let assert Ok(_) =
////     supervisor.new(supervisor.OneForOne)
////     |> supervisor.add(janitor.supervised(cleaner))
////     |> supervisor.start
////   cleaner
//// }
////
//// pub fn watch(cleaner, subscription) {
////   sinal.attach_owned(subscription, cleaner, owner: process.self())
//// }
//// ```
////
//// `sinal.with_janitor` binds a whole `with_subscriptions` scope to the
//// process that runs it.
////
//// ## Operational limits
////
//// - **The janitor must be running.** Registering through a janitor that is
////   not running is a wiring bug and panics in the caller; start the
////   janitor before the processes that register through it.
//// - **Registration is a call.** The caller waits up to five seconds for
////   the janitor and panics when it does not answer. The owner is
////   monitored either way, so a registration that completes late is still
////   removed when its owner exits.
//// - **Cleanup follows the owner's exit; it is not synchronous with it.**
////   An emitter can still reach the handler between the owner's exit and
////   the janitor's detach, and a callback already running in another
////   process finishes.
//// - **Tracking lives in the janitor process.** When the janitor itself
////   exits, the registrations it tracked stay attached and are no longer
////   bound to their owners; the replacement starts empty. Detaching by
////   hand still works.
//// - **The handler's closure is copied to the janitor** for the duration
////   of the registration call, as it is copied into the native handler
////   table.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision

/// A janitor's process name. Build it with `new`, run it with `supervised`.
pub opaque type Janitor {
  Janitor(name: process.Name(Message))
}

/// The janitor process's message type, needed only to create its
/// `process.Name`.
pub opaque type Message {
  Guard(
    owner: Pid,
    key: Dynamic,
    install: fn() -> Result(Nil, Nil),
    cleanup: fn() -> Nil,
    reply: process.Subject(Installation),
  )
  Release(owner: Pid, key: Dynamic)
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

type Owned {
  Owned(monitor: process.Monitor, cleanups: Dict(Dynamic, fn() -> Nil))
}

@external(erlang, "sinal_janitor_ffi", "capture")
fn capture(work: fn() -> a) -> Captured(a)

@external(erlang, "sinal_janitor_ffi", "reraise")
fn reraise(exception: Exception) -> a

@external(erlang, "erlang", "atom_to_binary")
fn name_to_string(name: process.Name(a)) -> String

const call_timeout = 5000

/// Describes a janitor. Starts no process; pair it with `supervised`.
/// Create the name once at application start, never per request.
pub fn new(name: process.Name(Message)) -> Janitor {
  Janitor(name:)
}

/// Describes the janitor's process for an OTP supervisor. A restarted
/// janitor starts with no tracked registrations.
pub fn supervised(janitor: Janitor) -> supervision.ChildSpecification(Janitor) {
  supervision.worker(fn() { start_janitor(janitor) })
}

fn start_janitor(
  janitor: Janitor,
) -> Result(actor.Started(Janitor), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    actor.initialised(dict.new())
    |> actor.selecting(
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(OwnerDown),
    )
    |> actor.returning(janitor)
    |> Ok
  })
  |> actor.named(janitor.name)
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  owners: Dict(Pid, Owned),
  message: Message,
) -> actor.Next(Dict(Pid, Owned), Message) {
  case message {
    Guard(owner:, key:, install:, cleanup:, reply:) ->
      case capture(install) {
        Returned(Ok(Nil)) -> {
          // Monitoring an owner that already exited delivers its `DOWN`
          // at once, so a registration made for a dead owner is removed
          // by the next message.
          let owners = track(owners, owner, key, cleanup)
          process.send(reply, Installed)
          actor.continue(owners)
        }
        Returned(Error(Nil)) -> {
          process.send(reply, Refused)
          actor.continue(owners)
        }
        Raised(exception) -> {
          process.send(reply, InstallRaised(exception))
          actor.continue(owners)
        }
      }
    Release(owner:, key:) -> actor.continue(forget(owners, owner, key))
    OwnerDown(process.ProcessDown(pid:, ..)) ->
      case dict.get(owners, pid) {
        Error(Nil) -> actor.continue(owners)
        Ok(Owned(cleanups:, ..)) -> {
          // One cleanup that raises must not skip the others or stop the
          // janitor.
          list.each(dict.values(cleanups), fn(cleanup) { capture(cleanup) })
          actor.continue(dict.delete(owners, pid))
        }
      }
    OwnerDown(process.PortDown(..)) -> actor.continue(owners)
  }
}

fn track(
  owners: Dict(Pid, Owned),
  owner: Pid,
  key: Dynamic,
  cleanup: fn() -> Nil,
) -> Dict(Pid, Owned) {
  let owned = case dict.get(owners, owner) {
    Ok(owned) -> owned
    Error(Nil) -> Owned(monitor: process.monitor(owner), cleanups: dict.new())
  }
  dict.insert(
    owners,
    owner,
    Owned(..owned, cleanups: dict.insert(owned.cleanups, key, cleanup)),
  )
}

fn forget(
  owners: Dict(Pid, Owned),
  owner: Pid,
  key: Dynamic,
) -> Dict(Pid, Owned) {
  case dict.get(owners, owner) {
    Error(Nil) -> owners
    Ok(Owned(monitor:, cleanups:)) -> {
      let cleanups = dict.delete(cleanups, key)
      case dict.is_empty(cleanups) {
        True -> {
          process.demonitor_process(monitor)
          dict.delete(owners, owner)
        }
        False -> dict.insert(owners, owner, Owned(monitor:, cleanups:))
      }
    }
  }
}

/// Runs `install` in the janitor and, when it returns `Ok`, binds `cleanup`
/// to `owner` under `key`: the janitor runs `cleanup` when `owner` exits,
/// unless `release` forgets the key first. An exception `install` raises is
/// re-raised in the caller. Panics when the janitor is not running or does
/// not answer.
@internal
pub fn guard(
  janitor: Janitor,
  owner owner: Pid,
  key key: Dynamic,
  install install: fn() -> Result(Nil, Nil),
  cleanup cleanup: fn() -> Nil,
  caller caller: String,
) -> Result(Nil, Nil) {
  case process.named(janitor.name) {
    Ok(_) -> Nil
    Error(Nil) ->
      panic as {
        caller
        <> ": the janitor "
        <> name_to_string(janitor.name)
        <> " is not running; supervise it with sinal/janitor.supervised before registering through it"
      }
  }
  let installation =
    process.call(process.named_subject(janitor.name), call_timeout, Guard(
      owner,
      key,
      install,
      cleanup,
      _,
    ))
  case installation {
    Installed -> Ok(Nil)
    Refused -> Error(Nil)
    InstallRaised(exception) -> reraise(exception)
  }
}

/// Makes the janitor forget `key` of `owner`, without running its cleanup.
/// Does nothing when the janitor is not running.
@internal
pub fn release(janitor: Janitor, owner owner: Pid, key key: Dynamic) -> Nil {
  let _ =
    capture(fn() {
      process.send(process.named_subject(janitor.name), Release(owner:, key:))
    })
  Nil
}

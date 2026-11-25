//// Every registration is bound to the process that made it: when that
//// process exits, for any reason, sinal's janitor detaches its handlers.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import gleeunit/should
import sinal
import sinal/fields

type Supervisor

@external(erlang, "owner_test_ffi", "janitor")
fn janitor() -> Result(Pid, Nil)

@external(erlang, "owner_test_ffi", "trace_receives")
fn trace_receives(pid: Pid) -> Nil

@external(erlang, "owner_test_ffi", "await_down_received")
fn await_down_received(pid: Pid, owner: Pid) -> Result(Nil, Nil)

@external(erlang, "owner_test_ffi", "sync")
fn sync(pid: Pid) -> Nil

@external(erlang, "owner_test_ffi", "suspend_supervisor")
fn suspend_supervisor() -> Supervisor

@external(erlang, "owner_test_ffi", "resume_supervisor")
fn resume_supervisor(supervisor: Supervisor) -> Nil

@external(erlang, "owner_test_ffi", "kill_and_await")
fn kill_and_await(pid: Pid) -> Nil

@external(erlang, "owner_test_ffi", "attach_native")
fn attach_native(id: String, event: List(Dynamic), target: Pid) -> Nil

@external(erlang, "owner_test_ffi", "native_attached")
fn native_attached(id: String) -> Bool

@external(erlang, "owner_test_ffi", "detach_native")
fn detach_native(id: String) -> Nil

@external(erlang, "erlang", "binary_to_atom")
fn atom(name: String) -> Dynamic

/// Starts tracing what the janitor receives, so that `settle` can wait for
/// an owner's `DOWN` to reach it. Call it before the owner can exit.
fn watch_janitor() -> Pid {
  let assert Ok(pid) = janitor()
  trace_receives(pid)
  pid
}

/// Returns once the janitor has handled the exit of `owner`: the janitor
/// has received the owner's `DOWN`, then answered a call queued behind it.
fn settle(janitor: Pid, owner: Pid) -> Nil {
  let assert Ok(Nil) = await_down_received(janitor, owner)
  sync(janitor)
}

/// Spawns a process that attaches `subscription`, reports ready and waits.
fn owner_of(subscription: sinal.Subscription) -> Pid {
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(_) = sinal.attach(subscription)
      process.send(ready, Nil)
      process.sleep_forever()
    })
  let assert Ok(Nil) = process.receive(ready, 1000)
  owner
}

fn counting(event: sinal.Event(Int, Nil), seen: process.Subject(Int)) {
  sinal.subscription(event, fn(n, _) { process.send(seen, n) })
}

pub fn a_killed_scope_owner_leaves_no_handler_test() {
  let janitor = watch_janitor()
  let event =
    sinal.event(["owner_test", "killed"], fields.int("n"), fields.empty())
  let seen = process.new_subject()
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      sinal.with_subscriptions(
        sinal.subscriptions([counting(event, seen)]),
        fn() {
          process.send(ready, Nil)
          process.sleep_forever()
        },
      )
    })
  let assert Ok(Nil) = process.receive(ready, 1000)
  sinal.emit(event, 1, Nil)
  process.receive(seen, 0) |> should.equal(Ok(1))

  process.kill(owner)
  settle(janitor, owner)

  sinal.emit(event, 2, Nil)
  process.receive(seen, 0) |> should.equal(Error(Nil))
}

pub fn an_owner_stopped_by_a_linked_exit_leaves_no_handler_test() {
  let janitor = watch_janitor()
  let event =
    sinal.event(["owner_test", "linked"], fields.int("n"), fields.empty())
  let seen = process.new_subject()
  let ready = process.new_subject()
  let peer = process.spawn_unlinked(process.sleep_forever)
  let owner =
    process.spawn_unlinked(fn() {
      // The owner does not trap exits, so the abnormal exit of the process
      // it links to terminates it without running any more of its code.
      process.link(peer)
      let assert Ok(_) = sinal.attach(counting(event, seen))
      process.send(ready, Nil)
      process.sleep_forever()
    })
  let assert Ok(Nil) = process.receive(ready, 1000)
  process.send_abnormal_exit(peer, "the linked process fails")
  settle(janitor, owner)

  sinal.emit(event, 1, Nil)
  process.receive(seen, 0) |> should.equal(Error(Nil))
}

pub fn an_owner_that_returns_normally_leaves_no_handler_test() {
  let janitor = watch_janitor()
  let event =
    sinal.event(["owner_test", "returned"], fields.int("n"), fields.empty())
  let seen = process.new_subject()
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let _ = sinal.observe(event, fn(n, _) { process.send(seen, n) })
      process.send(ready, Nil)
    })
  let assert Ok(Nil) = process.receive(ready, 1000)
  settle(janitor, owner)

  sinal.emit(event, 1, Nil)
  process.receive(seen, 0) |> should.equal(Error(Nil))
}

// The janitor keeps no record of its own: a restarted janitor reads the
// owners back from the native handler table, detaches the handlers of an
// owner that exited while no janitor ran, and monitors the owners still
// alive.
pub fn a_restarted_janitor_detaches_handlers_of_owners_that_exited_meanwhile_test() {
  let event =
    sinal.event(["owner_test", "restart"], fields.int("n"), fields.empty())
  let seen_by_dead = process.new_subject()
  let seen_by_live = process.new_subject()
  let dies_meanwhile = owner_of(counting(event, seen_by_dead))
  let survives = owner_of(counting(event, seen_by_live))
  let assert Ok(old_janitor) = janitor()

  let supervisor = suspend_supervisor()
  kill_and_await(old_janitor)
  kill_and_await(dies_meanwhile)
  resume_supervisor(supervisor)
  let assert Ok(new_janitor) = janitor()
  { new_janitor != old_janitor } |> should.be_true
  sync(new_janitor)

  sinal.emit(event, 1, Nil)
  process.receive(seen_by_dead, 0) |> should.equal(Error(Nil))
  process.receive(seen_by_live, 0) |> should.equal(Ok(1))

  trace_receives(new_janitor)
  process.kill(survives)
  settle(new_janitor, survives)
  sinal.emit(event, 2, Nil)
  process.receive(seen_by_live, 0) |> should.equal(Error(Nil))
}

pub fn detach_releases_the_owner_binding_test() {
  let janitor = watch_janitor()
  let event =
    sinal.event(["owner_test", "released"], fields.int("n"), fields.empty())
  let seen = process.new_subject()
  let subscription =
    counting(event, seen) |> sinal.with_id("owner_test_released")
  let ready = process.new_subject()
  let other =
    sinal.event(
      ["owner_test", "released_other"],
      fields.empty(),
      fields.empty(),
    )
  let first_owner =
    process.spawn_unlinked(fn() {
      let assert Ok(attachment) = sinal.attach(subscription)
      let assert Ok(Nil) = sinal.detach(attachment)
      // A second handler keeps the janitor monitoring this owner, so its
      // exit reaches the janitor.
      let _ = sinal.observe(other, fn(_, _) { Nil })
      process.send(ready, Nil)
      process.sleep_forever()
    })
  let assert Ok(Nil) = process.receive(ready, 1000)

  // This process reuses the id. The exit of the first owner must not
  // remove it.
  let assert Ok(reused) = sinal.attach(subscription)
  sinal.attach(subscription)
  |> should.equal(Error(sinal.AlreadyExists("owner_test_released")))
  process.kill(first_owner)
  settle(janitor, first_owner)

  sinal.emit(event, 1, Nil)
  process.receive(seen, 0) |> should.equal(Ok(1))
  let assert Ok(Nil) = sinal.detach(reused)
}

pub fn another_process_can_detach_an_attachment_test() {
  let event =
    sinal.event(["owner_test", "handed_over"], fields.int("n"), fields.empty())
  let seen = process.new_subject()
  let handed = process.new_subject()
  let _owner =
    process.spawn_unlinked(fn() {
      let assert Ok(attachment) = sinal.attach(counting(event, seen))
      process.send(handed, attachment)
      process.sleep_forever()
    })
  let assert Ok(attachment) = process.receive(handed, 1000)
  sinal.detach(attachment) |> should.equal(Ok(Nil))
  sinal.emit(event, 1, Nil)
  process.receive(seen, 0) |> should.equal(Error(Nil))
}

// A handler another library attached with plain `telemetry:attach/4` has
// no sinal owner: the janitor leaves it alone across its own restart, and
// it still receives what sinal emits.
pub fn native_handlers_of_other_libraries_are_left_alone_test() {
  let event =
    sinal.event(["owner_test", "native"], fields.int("n"), fields.empty())
  let id = "owner_test_native"
  let attacher =
    process.spawn_unlinked(fn() {
      attach_native(id, [atom("owner_test"), atom("native")], process.self())
      process.sleep_forever()
    })
  let assert Ok(old_janitor) = janitor()
  let supervisor = suspend_supervisor()
  kill_and_await(old_janitor)
  kill_and_await(attacher)
  resume_supervisor(supervisor)
  let assert Ok(new_janitor) = janitor()
  sync(new_janitor)

  native_attached(id) |> should.be_true
  detach_native(id)
  let _ = event
}

// A supervisor restarts a process that attaches under a stable id. The
// replacement attaches before or after the janitor handles the old
// process's exit; either way it gets the id and keeps it.
pub fn a_stable_id_passes_to_the_next_owner_after_its_owner_exits_test() {
  let janitor = watch_janitor()
  let event =
    sinal.event(["owner_test", "restarted"], fields.int("n"), fields.empty())
  let seen = process.new_subject()
  let subscription =
    counting(event, seen) |> sinal.with_id("owner_test_restarted")
  let old_owner = owner_of(subscription)

  kill_and_await(old_owner)
  let assert Ok(attachment) = sinal.attach(subscription)
  settle(janitor, old_owner)

  sinal.emit(event, 1, Nil)
  process.receive(seen, 0) |> should.equal(Ok(1))
  let assert Ok(Nil) = sinal.detach(attachment)
}

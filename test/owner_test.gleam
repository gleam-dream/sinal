import gleam/erlang/process.{type Pid}
import gleam/otp/static_supervisor as supervisor
import gleam/string
import gleeunit/should
import sinal
import sinal/fields
import sinal/janitor.{type Janitor}

@external(erlang, "janitor_test_ffi", "trace_receives")
fn trace_receives(pid: Pid) -> Nil

@external(erlang, "janitor_test_ffi", "await_down_received")
fn await_down_received(pid: Pid, owner: Pid) -> Result(Nil, Nil)

@external(erlang, "scope_test_ffi", "panic_message")
fn panic_message(work: fn() -> a) -> Result(String, Nil)

/// Starts a supervised janitor and traces what its process receives, so
/// `settle` can wait for an owner's `DOWN` to reach it.
fn started(label: String) -> #(Janitor, process.Name(janitor.Message)) {
  let name = process.new_name(label)
  let cleaner = janitor.new(name)
  let assert Ok(_) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(janitor.supervised(cleaner))
    |> supervisor.start
  let assert Ok(pid) = process.named(name)
  trace_receives(pid)
  #(cleaner, name)
}

/// Returns once the janitor has handled the exit of `owner`: first the
/// janitor receives the owner's `DOWN`, then it answers a call that queued
/// behind it.
fn settle(cleaner: Janitor, name: process.Name(janitor.Message), owner: Pid) {
  let assert Ok(pid) = process.named(name)
  let assert Ok(Nil) = await_down_received(pid, owner)
  call_through(cleaner)
}

/// Returns once the janitor has handled every message that reached it
/// before this call, including a release this process sent.
fn call_through(cleaner: Janitor) -> Nil {
  let probe =
    sinal.event(["owner_test", "probe"], fields.empty(), fields.empty())
  let assert Ok(attachment) =
    sinal.attach_owned(
      sinal.subscription(probe, fn(_, _) { Nil }),
      cleaner,
      owner: process.self(),
    )
  let assert Ok(Nil) = sinal.detach(attachment)
  Nil
}

fn await_exit(pid: Pid) -> Nil {
  let monitor = process.monitor(pid)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  Nil
}

pub fn a_killed_scope_owner_leaves_no_handler_test() {
  let #(cleaner, name) = started("janitor-killed-scope")
  let event =
    sinal.event(["owner_test", "killed"], fields.int("n"), fields.empty())
  let seen = process.new_subject()
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let plan =
        sinal.subscriptions([
          sinal.subscription(event, fn(n, _) { process.send(seen, n) }),
        ])
        |> sinal.with_janitor(cleaner)
      sinal.with_subscriptions(plan, fn() {
        process.send(ready, Nil)
        process.sleep_forever()
      })
    })
  let assert Ok(Nil) = process.receive(ready, 1000)
  sinal.emit(event, 1, Nil)
  process.receive(seen, 0) |> should.equal(Ok(1))

  process.kill(owner)
  settle(cleaner, name, owner)

  sinal.emit(event, 2, Nil)
  process.receive(seen, 0) |> should.equal(Error(Nil))
}

pub fn an_owner_stopped_by_a_linked_exit_leaves_no_handler_test() {
  let #(cleaner, name) = started("janitor-linked-exit")
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
      let assert Ok(_) =
        sinal.attach_owned(
          sinal.subscription(event, fn(n, _) { process.send(seen, n) }),
          cleaner,
          owner: process.self(),
        )
      process.send(ready, Nil)
      process.sleep_forever()
    })
  let assert Ok(Nil) = process.receive(ready, 1000)
  process.send_abnormal_exit(peer, "the linked process fails")
  settle(cleaner, name, owner)

  sinal.emit(event, 1, Nil)
  process.receive(seen, 0) |> should.equal(Error(Nil))
}

pub fn an_attachment_for_an_owner_that_already_exited_is_removed_test() {
  let #(cleaner, name) = started("janitor-dead-owner")
  let event =
    sinal.event(["owner_test", "dead"], fields.int("n"), fields.empty())
  let seen = process.new_subject()
  let owner = process.spawn_unlinked(fn() { Nil })
  await_exit(owner)

  let assert Ok(attachment) =
    sinal.attach_owned(
      sinal.subscription(event, fn(n, _) { process.send(seen, n) }),
      cleaner,
      owner:,
    )
  settle(cleaner, name, owner)

  sinal.emit(event, 1, Nil)
  process.receive(seen, 0) |> should.equal(Error(Nil))
  sinal.detach(attachment) |> should.equal(Error(Nil))
}

pub fn detach_releases_the_owner_binding_test() {
  let #(cleaner, _) = started("janitor-release")
  let event =
    sinal.event(["owner_test", "released"], fields.int("n"), fields.empty())
  let seen = process.new_subject()
  let subscription =
    sinal.subscription(event, fn(n, _) { process.send(seen, n) })
    |> sinal.with_id("owner_test_released")
  let owner = process.spawn_unlinked(process.sleep_forever)

  let assert Ok(owned) = sinal.attach_owned(subscription, cleaner, owner:)
  sinal.attach_owned(subscription, cleaner, owner:)
  |> should.equal(Error(sinal.AlreadyExists("owner_test_released")))
  let assert Ok(Nil) = sinal.detach(owned)

  // A later registration reuses the id without an owner. The exit of the
  // first registration's owner must not remove it.
  let assert Ok(unowned) = sinal.attach(subscription)
  process.kill(owner)
  await_exit(owner)
  call_through(cleaner)

  sinal.emit(event, 1, Nil)
  process.receive(seen, 0) |> should.equal(Ok(1))
  let assert Ok(Nil) = sinal.detach(unowned)
}

pub fn a_scope_bound_to_a_janitor_completes_and_detaches_test() {
  let #(cleaner, _) = started("janitor-scope")
  let event =
    sinal.event(["owner_test", "scope"], fields.int("n"), fields.empty())
  let seen = process.new_subject()
  let plan =
    sinal.subscriptions([
      sinal.subscription(event, fn(n, _) { process.send(seen, n) }),
    ])
    |> sinal.with_janitor(cleaner)
  let assert Ok(completion) =
    sinal.with_subscriptions(plan, fn() {
      sinal.emit(event, 1, Nil)
      "done"
    })
  completion.work_result |> should.equal("done")
  completion.cleanup_failures |> should.equal([])
  process.receive(seen, 0) |> should.equal(Ok(1))
  sinal.emit(event, 2, Nil)
  process.receive(seen, 0) |> should.equal(Error(Nil))
}

pub fn registering_through_a_janitor_that_is_not_running_panics_test() {
  let cleaner = janitor.new(process.new_name("janitor-absent"))
  let event =
    sinal.event(["owner_test", "absent"], fields.empty(), fields.empty())
  let assert Ok(message) =
    panic_message(fn() {
      sinal.attach_owned(
        sinal.subscription(event, fn(_, _) { Nil }),
        cleaner,
        owner: process.self(),
      )
    })
  string.contains(message, "is not running") |> should.be_true
  string.contains(message, "sinal.attach_owned") |> should.be_true
}

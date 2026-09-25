import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/otp/supervision
import gleeunit/should
import sinal
import sinal/fields
import sinal/forwarder
import sinal/internal/ffi

type TestCounters

@external(erlang, "sinal_forwarder_ffi", "new_counters")
fn test_new_counters() -> TestCounters

@external(erlang, "sinal_forwarder_ffi", "add_get")
fn test_add_get(counters: TestCounters, index: Int, delta: Int) -> Int

@external(erlang, "sinal_forwarder_ffi", "decrement_floor")
fn test_decrement_floor(counters: TestCounters, index: Int) -> Int

// (a) A handler's `self()` is the forwarder pid, not the caller's. If `emit`
// executed the handler directly in the caller instead of forwarding it, the
// observed pid would equal the test process's own pid rather than the
// forwarder's.
pub fn handler_executes_in_forwarder_process_not_caller_test() {
  let name = process.new_name("forwarder-self-pid")
  let assert Ok(fwd) = forwarder.new(name, 4)
  let spec = forwarder.supervised(fwd)
  let assert Ok(started) = spec.start()

  let assert Ok(ev) =
    sinal.event(
      [atom.create("forwarder_test"), atom.create("self_pid")],
      fields.empty(),
      fields.empty(),
    )
  let assert Ok(hid) = sinal.handler_id("forwarder-self-pid-handler")
  let subject = process.new_subject()
  let assert Ok(_attachment) =
    sinal.observe(hid, ev, fn(_, _) { process.send(subject, process.self()) })

  forwarder.emit(fwd, ev, Nil, Nil) |> should.equal(Ok(Nil))
  let assert Ok(handler_pid) = process.receive(subject, 200)
  handler_pid |> should.equal(started.pid)
  { handler_pid == process.self() } |> should.equal(False)
}

// Direct FFI-level proof that the decrement backing the in-flight counter
// never goes negative: it floors at 0 regardless of how many times it is
// called past the last real increment. This is what stands between a
// restart race (a queued Execute landing on a freshly-reset counter; see the
// module doc and the restart-under-load test below) and a permanently
// negative counter that would silently raise the effective capacity for the
// rest of that incarnation's life.
pub fn decrement_floor_never_goes_negative_test() {
  let counters = test_new_counters()

  test_decrement_floor(counters, 1) |> should.equal(0)
  test_decrement_floor(counters, 1) |> should.equal(0)

  test_add_get(counters, 1, 1) |> should.equal(1)
  test_decrement_floor(counters, 1) |> should.equal(0)
  test_decrement_floor(counters, 1) |> should.equal(0)

  test_add_get(counters, 1, 2) |> should.equal(2)
  test_decrement_floor(counters, 1) |> should.equal(1)
  test_decrement_floor(counters, 1) |> should.equal(0)
  test_decrement_floor(counters, 1) |> should.equal(0)
}

// (a2) `ForwarderUnavailable` and its rollback. Two emits before the
// forwarder is ever started, at capacity 1, must both report unavailability
// — never `CapacityExceeded` — which only holds if a failed send rolls its
// speculative increment back. (A subsequent `spec.start()` always drains the
// in-flight slot regardless, as documented on `Forwarder`'s restart-loss
// reporting, so proving the rollback has to happen before any start, not by
// checking admission after one.) Starting afterwards and admitting exactly
// one message at capacity 1 then confirms the forwarder is otherwise
// healthy.
pub fn emit_before_start_reports_unavailable_then_rolls_back_test() {
  let name = process.new_name("forwarder-unavailable")
  let assert Ok(fwd) = forwarder.new(name, 1)

  let assert Ok(ev) =
    sinal.event(
      [atom.create("forwarder_test"), atom.create("unavailable")],
      fields.empty(),
      fields.empty(),
    )

  // No process is registered under the forwarder's name yet. A mutation
  // that removes the rollback would leave the first failed send's increment
  // in place, so the second would read `CapacityExceeded` instead.
  forwarder.emit(fwd, ev, Nil, Nil)
  |> should.equal(Error(forwarder.ForwarderUnavailable))
  forwarder.emit(fwd, ev, Nil, Nil)
  |> should.equal(Error(forwarder.ForwarderUnavailable))

  let spec = forwarder.supervised(fwd)
  let assert Ok(_started) = spec.start()
  let assert Ok(hid) = sinal.handler_id("forwarder-unavailable-handler")
  let subject = process.new_subject()
  let assert Ok(_attachment) =
    sinal.observe(hid, ev, fn(_, _) { process.send(subject, Nil) })
  forwarder.emit(fwd, ev, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(subject, 200) |> should.equal(Ok(Nil))
}

// (b) `emit` returns before a blocked handler releases. Proven structurally,
// not by timing: the handler blocks forever on its own gate, and the test
// only sends the release *after* `emit` has already returned. A synchronous
// implementation would run the handler (and thus its indefinite wait) inside
// the `emit` call itself, before that release is ever sent — deadlocking the
// test process until the test runner's own timeout fails it.
pub fn emit_returns_before_blocked_handler_releases_test() {
  let name = process.new_name("forwarder-gate")
  let assert Ok(fwd) = forwarder.new(name, 4)
  let spec = forwarder.supervised(fwd)
  let assert Ok(_started) = spec.start()

  let assert Ok(ev) =
    sinal.event(
      [atom.create("forwarder_test"), atom.create("gate")],
      fields.empty(),
      fields.empty(),
    )
  let assert Ok(hid) = sinal.handler_id("forwarder-gate-handler")
  // The gate must be a subject owned by the forwarder process (the process
  // that will call `receive` on it), not the test process: `process.receive`
  // only ever finds messages in the calling process's own mailbox, and
  // `process.send` always delivers to the subject's original owner. So the
  // handler creates its own gate (running as it does inside the forwarder
  // process) and hands it back to the test over `entered`.
  let entered = process.new_subject()
  let done = process.new_subject()
  let assert Ok(_attachment) =
    sinal.observe(hid, ev, fn(_, _) {
      let gate = process.new_subject()
      process.send(entered, gate)
      process.receive_forever(gate)
      process.send(done, Nil)
    })

  forwarder.emit(fwd, ev, Nil, Nil) |> should.equal(Ok(Nil))

  let assert Ok(gate) = process.receive(entered, 200)
  process.send(gate, Nil)
  process.receive(done, 200) |> should.equal(Ok(Nil))
}

// (c) Capacity 2 plus a blocked handler: a third emit is rejected, and after
// releasing the handler and observing a sentinel drain, capacity is
// available again. Removing the post-execute decrement, or checking capacity
// against the pre-increment value, both desynchronise the counter from the
// number of real in-flight messages and would surface here.
pub fn capacity_exceeded_then_recovers_after_release_and_sentinel_test() {
  let name = process.new_name("forwarder-capacity")
  let assert Ok(fwd) = forwarder.new(name, 2)
  let spec = forwarder.supervised(fwd)
  let assert Ok(_started) = spec.start()

  let assert Ok(block_ev) =
    sinal.event(
      [atom.create("forwarder_test"), atom.create("capacity_block")],
      fields.empty(),
      fields.empty(),
    )
  let assert Ok(sentinel_ev) =
    sinal.event(
      [atom.create("forwarder_test"), atom.create("capacity_sentinel")],
      fields.empty(),
      fields.empty(),
    )
  let assert Ok(block_hid) = sinal.handler_id("forwarder-capacity-block")
  let assert Ok(sentinel_hid) = sinal.handler_id("forwarder-capacity-sentinel")

  // The gate must be owned by the forwarder process (see the note in the
  // (b) test above), so the handler creates a fresh one on each invocation
  // and hands it back over `entered`.
  let entered = process.new_subject()
  let sentinel_subject = process.new_subject()
  let assert Ok(_block_attachment) =
    sinal.observe(block_hid, block_ev, fn(_, _) {
      let gate = process.new_subject()
      process.send(entered, gate)
      let assert Ok(Nil) = process.receive(gate, 2000)
      Nil
    })
  let assert Ok(_sentinel_attachment) =
    sinal.observe(sentinel_hid, sentinel_ev, fn(_, _) {
      process.send(sentinel_subject, Nil)
    })

  // First emit occupies one of two slots and blocks the forwarder process.
  forwarder.emit(fwd, block_ev, Nil, Nil) |> should.equal(Ok(Nil))
  let assert Ok(gate_1) = process.receive(entered, 200)

  // Second emit fills the remaining slot; it queues behind the blocked
  // handler but is still admitted (2 in flight, capacity 2).
  forwarder.emit(fwd, sentinel_ev, Nil, Nil) |> should.equal(Ok(Nil))

  // Third emit exceeds capacity while both slots are occupied.
  forwarder.emit(fwd, sentinel_ev, Nil, Nil)
  |> should.equal(Error(forwarder.CapacityExceeded))

  // Release the blocked handler and let the queued sentinel drain.
  process.send(gate_1, Nil)
  process.receive(sentinel_subject, 200) |> should.equal(Ok(Nil))

  // Capacity is fully restored to 2, not left permanently short by a phantom
  // unit from the earlier rejection: re-run the same occupy-both-slots
  // pattern and confirm both are admitted again. A rejected attempt that
  // checked the pre-increment value but still incremented on the rejected
  // path, with no rollback, would leave a leftover unit here and surface as
  // a spurious `CapacityExceeded` on the second of these two.
  forwarder.emit(fwd, block_ev, Nil, Nil) |> should.equal(Ok(Nil))
  let assert Ok(gate_2) = process.receive(entered, 200)
  forwarder.emit(fwd, sentinel_ev, Nil, Nil) |> should.equal(Ok(Nil))
  process.send(gate_2, Nil)
  process.receive(sentinel_subject, 200) |> should.equal(Ok(Nil))
}

// (d) Exactly one dropped event, with rejected: 1, emitted from the
// forwarder's own pid. A caller-side report would carry the test process's
// pid instead; a double report would deliver a second event on the same
// subject.
pub fn capacity_exceeded_emits_single_dropped_event_from_forwarder_test() {
  let name = process.new_name("forwarder-dropped")
  let assert Ok(fwd) = forwarder.new(name, 1)
  let spec = forwarder.supervised(fwd)
  let assert Ok(started) = spec.start()

  let assert Ok(block_ev) =
    sinal.event(
      [atom.create("forwarder_test"), atom.create("dropped_block")],
      fields.empty(),
      fields.empty(),
    )
  let assert Ok(block_hid) = sinal.handler_id("forwarder-dropped-block")
  // See the (b) test's note: the gate must be owned by the forwarder
  // process, so the handler creates it and hands it back over `entered`.
  let entered = process.new_subject()
  let assert Ok(_block_attachment) =
    sinal.observe(block_hid, block_ev, fn(_, _) {
      let gate = process.new_subject()
      process.send(entered, gate)
      let assert Ok(Nil) = process.receive(gate, 2000)
      Nil
    })

  let assert Ok(dropped_hid) = sinal.handler_id("forwarder-dropped-observer")
  let dropped_subject = process.new_subject()
  let assert Ok(_dropped_attachment) =
    sinal.observe(dropped_hid, forwarder.dropped_event(), fn(dropped, _meta) {
      process.send(dropped_subject, #(dropped, process.self()))
    })

  forwarder.emit(fwd, block_ev, Nil, Nil) |> should.equal(Ok(Nil))
  let assert Ok(gate) = process.receive(entered, 200)

  // Capacity is 1 and already occupied by the blocked handler.
  forwarder.emit(fwd, block_ev, Nil, Nil)
  |> should.equal(Error(forwarder.CapacityExceeded))

  // Release so the queued ReportDrops message can drain and be reported.
  process.send(gate, Nil)

  let assert Ok(#(dropped, reporter_pid)) =
    process.receive(dropped_subject, 200)
  dropped |> should.equal(forwarder.Dropped(rejected: 1, lost: 0))
  reporter_pid |> should.equal(started.pid)

  process.receive(dropped_subject, 100) |> should.be_error()
}

// (d2) Coalescing: two drops accumulated while the handler is still blocked
// must fold into exactly one `Dropped(rejected: 2, lost: 0)`, not two
// separate `rejected: 1` events. A mutation that reports on every drop
// (rather than only the sender whose increment causes the 0→1 transition)
// would instead deliver two events here.
pub fn concurrent_drops_coalesce_into_one_dropped_event_test() {
  let name = process.new_name("forwarder-coalesce")
  let assert Ok(fwd) = forwarder.new(name, 1)
  let spec = forwarder.supervised(fwd)
  let assert Ok(started) = spec.start()

  let assert Ok(block_ev) =
    sinal.event(
      [atom.create("forwarder_test"), atom.create("coalesce_block")],
      fields.empty(),
      fields.empty(),
    )
  let assert Ok(block_hid) = sinal.handler_id("forwarder-coalesce-block")
  let entered = process.new_subject()
  let assert Ok(_block_attachment) =
    sinal.observe(block_hid, block_ev, fn(_, _) {
      let gate = process.new_subject()
      process.send(entered, gate)
      let assert Ok(Nil) = process.receive(gate, 2000)
      Nil
    })

  let assert Ok(dropped_hid) = sinal.handler_id("forwarder-coalesce-dropped")
  let dropped_subject = process.new_subject()
  let assert Ok(_dropped_attachment) =
    sinal.observe(dropped_hid, forwarder.dropped_event(), fn(dropped, _meta) {
      process.send(dropped_subject, #(dropped, process.self()))
    })

  forwarder.emit(fwd, block_ev, Nil, Nil) |> should.equal(Ok(Nil))
  let assert Ok(gate) = process.receive(entered, 200)

  // Both of these are rejected while the single slot stays occupied; the
  // first causes the drop slot's 0→1 transition and queues one `ReportDrops`,
  // the second only adds to the same accumulating count.
  forwarder.emit(fwd, block_ev, Nil, Nil)
  |> should.equal(Error(forwarder.CapacityExceeded))
  forwarder.emit(fwd, block_ev, Nil, Nil)
  |> should.equal(Error(forwarder.CapacityExceeded))

  process.send(gate, Nil)

  let assert Ok(#(dropped, reporter_pid)) =
    process.receive(dropped_subject, 200)
  dropped |> should.equal(forwarder.Dropped(rejected: 2, lost: 0))
  reporter_pid |> should.equal(started.pid)

  process.receive(dropped_subject, 100) |> should.be_error()
}

// (e) A raising handler is detached by native telemetry's own failure
// isolation; the forwarder process itself survives unchanged and keeps
// draining later messages.
pub fn raising_handler_is_detached_and_forwarder_survives_test() {
  let name = process.new_name("forwarder-raise")
  let assert Ok(fwd) = forwarder.new(name, 4)
  let spec = forwarder.supervised(fwd)
  let assert Ok(started) = spec.start()

  let assert Ok(raise_ev) =
    sinal.event(
      [atom.create("forwarder_test"), atom.create("raise")],
      fields.empty(),
      fields.empty(),
    )
  let assert Ok(sentinel_ev) =
    sinal.event(
      [atom.create("forwarder_test"), atom.create("raise_sentinel")],
      fields.empty(),
      fields.empty(),
    )
  let assert Ok(raise_hid) = sinal.handler_id("forwarder-raise-handler")
  let assert Ok(sentinel_hid) = sinal.handler_id("forwarder-raise-sentinel")

  let assert Ok(_raise_attachment) =
    sinal.observe(raise_hid, raise_ev, fn(_, _) {
      panic as "forwarder handler panic"
    })

  let failure_event = [
    atom.create("telemetry"),
    atom.create("handler"),
    atom.create("failure"),
  ]
  let failure_listener_id =
    ffi.to_dynamic(atom.create("forwarder_raise_failure_listener"))
  let failure_subject = process.new_subject()
  let assert Ok(Nil) =
    ffi.telemetry_attach_many(
      failure_listener_id,
      [failure_event],
      fn(_, _, _, _) { process.send(failure_subject, Nil) },
      ffi.to_dynamic(Nil),
    )

  let sentinel_subject = process.new_subject()
  let assert Ok(_sentinel_attachment) =
    sinal.observe(sentinel_hid, sentinel_ev, fn(_, _) {
      process.send(sentinel_subject, process.self())
    })

  forwarder.emit(fwd, raise_ev, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(failure_subject, 200) |> should.equal(Ok(Nil))

  forwarder.emit(fwd, sentinel_ev, Nil, Nil) |> should.equal(Ok(Nil))
  let assert Ok(pid_after) = process.receive(sentinel_subject, 200)
  pid_after |> should.equal(started.pid)

  let _ = ffi.telemetry_detach(failure_listener_id)
}

// (f) Killing the forwarder with 2 messages in flight makes the next
// incarnation report lost: 2 and reset the counter (omitting the reset would
// keep capacity permanently exhausted for the still-live `Forwarder` value).
pub fn killed_incarnation_reports_lost_and_resets_counter_test() {
  let name = process.new_name("forwarder-kill")
  // Capacity equals the lost count so a leftover, unreset ghost count would
  // immediately exhaust it: the closing admission below only succeeds if the
  // in-flight slot was truly reset to 0, not merely read.
  let assert Ok(fwd) = forwarder.new(name, 2)
  let spec = forwarder.supervised(fwd)
  let assert Ok(started1) = spec.start()

  let assert Ok(block_ev) =
    sinal.event(
      [atom.create("forwarder_test"), atom.create("kill_block")],
      fields.empty(),
      fields.empty(),
    )
  let assert Ok(block_hid) = sinal.handler_id("forwarder-kill-block")
  // See the (b) test's note: the gate must be owned by the forwarder
  // process, so the handler creates it and hands it back over `entered`.
  // It is never released here — the forwarder is killed while blocked.
  let entered = process.new_subject()
  let assert Ok(_block_attachment) =
    sinal.observe(block_hid, block_ev, fn(_, _) {
      let gate = process.new_subject()
      process.send(entered, gate)
      let assert Ok(Nil) = process.receive(gate, 5000)
      Nil
    })

  // First emit is picked up and blocks the actor before it can decrement.
  forwarder.emit(fwd, block_ev, Nil, Nil) |> should.equal(Ok(Nil))
  let assert Ok(_gate) = process.receive(entered, 200)
  // Second emit is admitted but queues behind the blocked handler, so it
  // never decrements either.
  forwarder.emit(fwd, block_ev, Nil, Nil) |> should.equal(Ok(Nil))

  let monitor = process.monitor(started1.pid)
  // `actor.start` links the forwarder to this test process; unlink first so
  // the untrappable kill below only takes down the forwarder.
  process.unlink(started1.pid)
  process.kill(started1.pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(_down) = process.selector_receive(selector, 500)

  let assert Ok(dropped_hid) =
    sinal.handler_id("forwarder-kill-dropped-observer")
  let dropped_subject = process.new_subject()
  let assert Ok(_dropped_attachment) =
    sinal.observe(dropped_hid, forwarder.dropped_event(), fn(dropped, _meta) {
      process.send(dropped_subject, dropped)
    })

  let assert Ok(started2) = spec.start()
  started2.pid |> should.not_equal(started1.pid)

  let assert Ok(dropped) = process.receive(dropped_subject, 200)
  dropped |> should.equal(forwarder.Dropped(rejected: 0, lost: 2))

  // The counter is reset: a fresh send is admitted rather than rejected.
  let assert Ok(sentinel_ev) =
    sinal.event(
      [atom.create("forwarder_test"), atom.create("kill_sentinel")],
      fields.empty(),
      fields.empty(),
    )
  let assert Ok(sentinel_hid) = sinal.handler_id("forwarder-kill-sentinel")
  let sentinel_subject = process.new_subject()
  let assert Ok(_sentinel_attachment) =
    sinal.observe(sentinel_hid, sentinel_ev, fn(_, _) {
      process.send(sentinel_subject, Nil)
    })
  forwarder.emit(fwd, sentinel_ev, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(sentinel_subject, 200) |> should.equal(Ok(Nil))
}

// (f2) The drop slot is drained on restart too. A `ReportDrops` message that
// is still queued (never processed, because the handler ahead of it in the
// mailbox is blocked) when the forwarder is killed must not silently vanish:
// the next incarnation's own restart-loss drain picks the accumulated drop
// count back up.
pub fn restart_drains_drop_slot_when_killed_before_report_drops_test() {
  let name = process.new_name("forwarder-drop-restart")
  let assert Ok(fwd) = forwarder.new(name, 1)
  let spec = forwarder.supervised(fwd)
  let assert Ok(started1) = spec.start()

  let assert Ok(block_ev) =
    sinal.event(
      [atom.create("forwarder_test"), atom.create("drop_restart_block")],
      fields.empty(),
      fields.empty(),
    )
  let assert Ok(block_hid) = sinal.handler_id("forwarder-drop-restart-block")
  let entered = process.new_subject()
  let assert Ok(_block_attachment) =
    sinal.observe(block_hid, block_ev, fn(_, _) {
      let gate = process.new_subject()
      process.send(entered, gate)
      let assert Ok(Nil) = process.receive(gate, 5000)
      Nil
    })

  forwarder.emit(fwd, block_ev, Nil, Nil) |> should.equal(Ok(Nil))
  let assert Ok(_gate) = process.receive(entered, 200)

  // Capacity 1 is already occupied by the blocked handler: this is rejected,
  // and the resulting `ReportDrops` queues behind the still-blocked handler,
  // so this incarnation never gets to process it.
  forwarder.emit(fwd, block_ev, Nil, Nil)
  |> should.equal(Error(forwarder.CapacityExceeded))

  let monitor = process.monitor(started1.pid)
  process.unlink(started1.pid)
  process.kill(started1.pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(_down) = process.selector_receive(selector, 500)

  let assert Ok(dropped_hid) =
    sinal.handler_id("forwarder-drop-restart-dropped")
  let dropped_subject = process.new_subject()
  let assert Ok(_dropped_attachment) =
    sinal.observe(dropped_hid, forwarder.dropped_event(), fn(dropped, _meta) {
      process.send(dropped_subject, dropped)
    })

  let assert Ok(_started2) = spec.start()
  let assert Ok(dropped) = process.receive(dropped_subject, 200)
  { dropped.rejected > 0 } |> should.equal(True)
}

// (race) Restart racing concurrent emitters must never leave the in-flight
// counter negative, which would silently raise the effective capacity for
// the rest of that incarnation's life. `gleam_otp` registers a restarting
// actor's name before its initialiser runs, so a concurrent emit can land an
// Execute message in the new incarnation's mailbox before that incarnation's
// own reset-to-0 has run (see the module doc and `decrement_floor_never_
// goes_negative_test` above, which is what actually prevents the negative
// value). This test drives many concurrent emitters through several forced
// restarts and then checks capacity is still exactly enforced on whichever
// incarnation is left running, without an intervening "clean" restart that
// would mask the leak by resetting the counter again.
//
// This is a best-effort stress test, not a guaranteed reproduction: hitting
// the exact race window is not deterministic. It cannot go red on a correct
// implementation (capacity is respected whether or not the window is hit),
// and it raises the odds of catching a regression that removes the floored
// decrement, without being able to guarantee it on any single run.
pub fn restart_under_load_never_inflates_capacity_test() {
  let name = process.new_name("forwarder-race")
  let assert Ok(fwd) = forwarder.new(name, 3)
  let spec = forwarder.supervised(fwd)
  let assert Ok(started) = spec.start()

  let assert Ok(ev) =
    sinal.event(
      [atom.create("forwarder_test"), atom.create("race")],
      fields.empty(),
      fields.empty(),
    )
  let assert Ok(hid) = sinal.handler_id("forwarder-race-handler")
  let assert Ok(_attachment) = sinal.observe(hid, ev, fn(_, _) { Nil })

  let done = process.new_subject()
  let hammer = fn() {
    process.spawn_unlinked(fn() {
      one_to(300)
      |> list.each(fn(_) {
        let _ = forwarder.emit(fwd, ev, Nil, Nil)
        Nil
      })
      process.send(done, Nil)
    })
    Nil
  }
  hammer()
  hammer()
  hammer()

  restart_forwarder_a_few_times(spec, started.pid, 5)

  process.receive(done, 2000) |> should.equal(Ok(Nil))
  process.receive(done, 2000) |> should.equal(Ok(Nil))
  process.receive(done, 2000) |> should.equal(Ok(Nil))

  // Whatever incarnation is now running is exactly the one that lived
  // through the race above (no further restart here, which would reset the
  // counter and hide a leak). Capacity must still be exactly 3: three
  // concurrent sends admit, a fourth does not.
  let assert Ok(block_hid) = sinal.handler_id("forwarder-race-block")
  let entered = process.new_subject()
  let assert Ok(_block_attachment) =
    sinal.observe(block_hid, ev, fn(_, _) {
      let gate = process.new_subject()
      process.send(entered, gate)
      let assert Ok(Nil) = process.receive(gate, 2000)
      Nil
    })

  forwarder.emit(fwd, ev, Nil, Nil) |> should.equal(Ok(Nil))
  let assert Ok(gate) = process.receive(entered, 200)
  forwarder.emit(fwd, ev, Nil, Nil) |> should.equal(Ok(Nil))
  forwarder.emit(fwd, ev, Nil, Nil) |> should.equal(Ok(Nil))
  forwarder.emit(fwd, ev, Nil, Nil)
  |> should.equal(Error(forwarder.CapacityExceeded))

  process.send(gate, Nil)
}

fn restart_forwarder_a_few_times(
  spec: supervision.ChildSpecification(Nil),
  current_pid: process.Pid,
  remaining: Int,
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      // Wait for the confirmed death (and so the confirmed name
      // un-registration) of the current incarnation before starting the
      // next one. This only removes an uninteresting harness race (starting
      // before the old name is free); it does not narrow the actual race
      // under test, which is entirely within the new incarnation's own
      // registration-then-initialise window.
      let monitor = process.monitor(current_pid)
      process.unlink(current_pid)
      process.kill(current_pid)
      let selector =
        process.new_selector()
        |> process.select_specific_monitor(monitor, fn(down) { down })
      let assert Ok(_down) = process.selector_receive(selector, 1000)
      let assert Ok(started) = spec.start()
      restart_forwarder_a_few_times(spec, started.pid, remaining - 1)
    }
  }
}

// (g) An encoding failure is reported without ever reaching the counters, so
// it never consumes capacity.
pub fn encoding_failure_does_not_consume_capacity_test() {
  let name = process.new_name("forwarder-encode-fail")
  let assert Ok(fwd) = forwarder.new(name, 1)
  let spec = forwarder.supervised(fwd)
  let assert Ok(_started) = spec.start()

  let strict_field =
    fields.field(
      atom.create("value"),
      fn(n: Int) {
        case n >= 0 {
          True -> Ok(dynamic.int(n))
          False -> Error(fields.FieldEncodeError("negative prohibited"))
        }
      },
      fn(raw) {
        case decode.run(raw, decode.int) {
          Ok(n) -> Ok(n)
          Error(_) -> Error(fields.FieldDecodeError("expected int"))
        }
      },
    )
  let assert Ok(ev) =
    sinal.event(
      [atom.create("forwarder_test"), atom.create("encode_fail")],
      strict_field,
      fields.empty(),
    )

  forwarder.emit(fwd, ev, -1, Nil)
  |> should.equal(
    Error(
      forwarder.ForwardEncodingFailed(fields.FieldEncodeError(
        "negative prohibited",
      )),
    ),
  )

  // A full admission still succeeds: the rejected encode never touched the
  // single-slot capacity.
  let assert Ok(sentinel_hid) = sinal.handler_id("forwarder-encode-fail-ok")
  let sentinel_subject = process.new_subject()
  let assert Ok(_attachment) =
    sinal.observe(sentinel_hid, ev, fn(value, _) {
      process.send(sentinel_subject, value)
    })
  forwarder.emit(fwd, ev, 5, Nil) |> should.equal(Ok(Nil))
  process.receive(sentinel_subject, 200) |> should.equal(Ok(5))
}

// (h) 100 emits from one producer are dispatched in the order sent, per
// native BEAM per-sender message ordering.
pub fn hundred_emits_from_one_producer_arrive_in_order_test() {
  let name = process.new_name("forwarder-order")
  let assert Ok(fwd) = forwarder.new(name, 200)
  let spec = forwarder.supervised(fwd)
  let assert Ok(_started) = spec.start()

  let assert Ok(ev) =
    sinal.event(
      [atom.create("forwarder_test"), atom.create("order")],
      fields.int(atom.create("n")),
      fields.empty(),
    )
  let assert Ok(hid) = sinal.handler_id("forwarder-order-handler")
  let subject = process.new_subject()
  let assert Ok(_attachment) =
    sinal.observe(hid, ev, fn(n, _) { process.send(subject, n) })

  let sequence = one_to(100)

  sequence
  |> list.each(fn(n) {
    forwarder.emit(fwd, ev, n, Nil) |> should.equal(Ok(Nil))
  })

  let received =
    sequence
    |> list.map(fn(_) {
      let assert Ok(n) = process.receive(subject, 500)
      n
    })
  received |> should.equal(sequence)
}

fn one_to(n: Int) -> List(Int) {
  count_up(1, n, [])
}

fn count_up(current: Int, stop: Int, acc: List(Int)) -> List(Int) {
  case current > stop {
    True -> list.reverse(acc)
    False -> count_up(current + 1, stop, [current, ..acc])
  }
}

// (i) Zero and negative capacities are rejected without allocating anything
// runnable.
pub fn non_positive_capacity_is_rejected_test() {
  let name = process.new_name("forwarder-invalid-capacity")
  forwarder.new(name, 0) |> should.equal(Error(forwarder.InvalidCapacity))
  forwarder.new(name, -3) |> should.equal(Error(forwarder.InvalidCapacity))
}

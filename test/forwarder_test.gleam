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

@external(erlang, "forwarder_test_ffi", "message_queue_len")
fn message_queue_len(pid: process.Pid) -> Int

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

  // Both drops are counted, and the first incarnation reports them from its
  // own process as `unavailable`, never as `rejected`: they took no capacity.
  let dropped = observe_dropped("forwarder-unavailable-dropped", name)
  let spec = forwarder.supervised(fwd)
  let assert Ok(started) = spec.start()
  process.receive(dropped.1, 200)
  |> should.equal(
    Ok(#(forwarder.Dropped(rejected: 0, lost: 0, unavailable: 2), started.pid)),
  )
  process.receive(dropped.1, 100) |> should.be_error()
  let assert Ok(Nil) = sinal.detach(dropped.0)
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
  dropped
  |> should.equal(forwarder.Dropped(rejected: 1, lost: 0, unavailable: 0))
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
  dropped
  |> should.equal(forwarder.Dropped(rejected: 2, lost: 0, unavailable: 0))
  reporter_pid |> should.equal(started.pid)

  process.receive(dropped_subject, 100) |> should.be_error()
}

// (d3) The two guards against duplicate drop reports are independently
// observable. `report_drop` only sends `ReportDrops` on the sender whose
// increment causes the drop slot's 0→1 transition; `handle_message`'s
// `ReportDrops` branch separately re-checks `rejected > 0` before emitting.
// The test above ((d2)) only watches the resulting `dropped_event`s, and
// cannot tell the two guards apart: with only the receiver-side recheck
// removed, (d2) still passes, because the sender-side guard alone already
// keeps every drop-storm down to one `ReportDrops` message, so there is
// never a second, already-drained read for the recheck to have to swallow.
// And with only the sender-side guard removed, (d2) *also* still passes,
// because the receiver-side recheck swallows every `ReportDrops` beyond the
// first (each of the extras finds the drop slot already back at 0 and skips
// emitting) — the emitted events are identical either way. So this test
// reads the forwarder's own mailbox length before anything is processed,
// which is where the sender-side guard's effect actually lives: five
// concurrent overflow attempts against a single occupied slot must leave
// exactly one queued message, not five. Removing only the receiver-side
// recheck cannot change this count (it only affects processing, not
// sending), so this test isolates the sender-side guard specifically.
pub fn concurrent_drops_queue_single_report_message_test() {
  let name = process.new_name("forwarder-mailbox")
  let assert Ok(fwd) = forwarder.new(name, 1)
  let spec = forwarder.supervised(fwd)
  let assert Ok(started) = spec.start()

  let assert Ok(block_ev) =
    sinal.event(
      [atom.create("forwarder_test"), atom.create("mailbox_block")],
      fields.empty(),
      fields.empty(),
    )
  let assert Ok(block_hid) = sinal.handler_id("forwarder-mailbox-block")
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

  // Occupies the sole slot and blocks the forwarder process mid-handler, so
  // nothing sent afterwards is dequeued until the gate below is released.
  forwarder.emit(fwd, block_ev, Nil, Nil) |> should.equal(Ok(Nil))
  let assert Ok(gate) = process.receive(entered, 200)

  // Five concurrent overflow attempts. Each one's `emit` call only returns
  // after its own `report_drop` has already run to completion (the send, if
  // any, happens synchronously inside `emit`), so collecting all five
  // replies below guarantees every attempt has already had its chance to
  // queue a message before the mailbox is inspected.
  let done = process.new_subject()
  list.each(one_to(5), fn(_) {
    process.spawn_unlinked(fn() {
      forwarder.emit(fwd, block_ev, Nil, Nil)
      |> should.equal(Error(forwarder.CapacityExceeded))
      process.send(done, Nil)
    })
    Nil
  })
  list.each(one_to(5), fn(_) {
    process.receive(done, 500) |> should.equal(Ok(Nil))
  })

  // The forwarder is still parked on the gate, so nothing has been dequeued:
  // whatever is in its mailbox now is exactly what the five attempts above
  // produced between them. A mutation that sends `ReportDrops` on every
  // increment rather than only the 0→1 transition would leave five messages
  // queued here instead of one.
  message_queue_len(started.pid) |> should.equal(1)

  process.send(gate, Nil)
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
  dropped
  |> should.equal(forwarder.Dropped(rejected: 0, lost: 2, unavailable: 0))

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
//
// A deterministic reproduction was considered and rejected. The window this
// races against is entirely inside `gleam_otp`'s own `actor.start`: it
// registers the restarting actor's name, then runs this module's
// initialiser, and nothing in `sinal/forwarder` runs between those two
// steps for a test to hook. The only way to widen the window on demand
// would be to add a test-only delay inside the initialiser itself (a
// production code path) purely so a test elsewhere could schedule a
// concurrent `emit` into it — a permanent seam in shipped code for one
// test's benefit, which this module avoids. `erlang:suspend_process`
// cannot substitute for that seam either: there is no way to name the new
// incarnation's pid until it has already registered, and by then the
// initialiser is typically already running or done, so suspending it only
// after the fact narrows nothing. Hammering many concurrent emitters
// through several forced restarts, as below, is the practical alternative.
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

  // Also watches every `dropped_event` emitted across the whole run. This is
  // the same restart-registration-before-initialiser window that can inflate
  // the in-flight counter (see the module doc and the test's main comment);
  // it is also the only window in which `handle_message`'s `ReportDrops`
  // branch can find `rejected` already back at 0 (drained concurrently by a
  // restarting incarnation's own drain) and would, without its `rejected > 0`
  // recheck, emit a spurious empty `Dropped(0, 0, 0)`. Hitting
  // that exact interleaving is exactly as non-deterministic as the capacity
  // race below, so this assertion is best-effort in the same sense: it
  // cannot go red on a correct implementation, and it raises (without
  // guaranteeing) the odds of catching a regression that removes the
  // recheck.
  let assert Ok(dropped_hid) = sinal.handler_id("forwarder-race-dropped")
  let dropped_subject = process.new_subject()
  let assert Ok(_dropped_attachment) =
    sinal.observe(dropped_hid, forwarder.dropped_event(), fn(dropped, _meta) {
      process.send(dropped_subject, dropped)
    })

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

  // Drain whatever `dropped_event`s the run produced (real drops from the
  // hammering above are expected and fine) and confirm none of them is the
  // spurious empty report the receiver-side recheck exists to prevent.
  drain_dropped(dropped_subject, [])
  |> list.each(fn(dropped) {
    { dropped.rejected == 0 && dropped.lost == 0 && dropped.unavailable == 0 }
    |> should.equal(False)
  })
}

fn drain_dropped(
  subject: process.Subject(forwarder.Dropped),
  acc: List(forwarder.Dropped),
) -> List(forwarder.Dropped) {
  case process.receive(subject, 50) {
    Ok(dropped) -> drain_dropped(subject, [dropped, ..acc])
    Error(Nil) -> acc
  }
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

// Observes `dropped_event` for one forwarder only, recording each report with
// the pid of the process that emitted it. Filtering by the forwarder's name
// keeps a report from another test's forwarder out of this test's mailbox.
fn observe_dropped(
  id: String,
  name: process.Name(forwarder.Message),
) -> #(sinal.Attachment, process.Subject(#(forwarder.Dropped, process.Pid))) {
  let assert Ok(hid) = sinal.handler_id(id)
  let subject = process.new_subject()
  let wanted = atom.to_string(name_to_atom(name))
  let assert Ok(attachment) =
    sinal.observe(hid, forwarder.dropped_event(), fn(dropped, meta) {
      case meta.forwarder == wanted {
        True -> process.send(subject, #(dropped, process.self()))
        False -> Nil
      }
    })
  #(attachment, subject)
}

@external(erlang, "forwarder_test_ffi", "identity")
fn name_to_atom(name: process.Name(a)) -> atom.Atom

fn kill_and_wait(pid: process.Pid) -> Nil {
  let monitor = process.monitor(pid)
  process.unlink(pid)
  process.kill(pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(_down) = process.selector_receive(selector, 500)
  Nil
}

// (h) Sends that find a crashed forwarder down are counted, and the next
// incarnation started from the same `Forwarder` reports them once as
// `unavailable`. They never took an in-flight slot, so they appear neither
// as `lost` nor as `rejected`, and the report resets the count: a later
// restart with no new unavailable drops reports nothing.
pub fn unavailable_drops_while_down_are_reported_by_the_next_incarnation_test() {
  let name = process.new_name("forwarder-down")
  let assert Ok(fwd) = forwarder.new(name, 1)
  let spec = forwarder.supervised(fwd)
  let assert Ok(started1) = spec.start()
  let assert Ok(ev) =
    sinal.event(
      [atom.create("forwarder_test"), atom.create("down")],
      fields.empty(),
      fields.empty(),
    )
  let dropped = observe_dropped("forwarder-down-dropped", name)

  kill_and_wait(started1.pid)
  forwarder.emit(fwd, ev, Nil, Nil)
  |> should.equal(Error(forwarder.ForwarderUnavailable))
  forwarder.emit(fwd, ev, Nil, Nil)
  |> should.equal(Error(forwarder.ForwarderUnavailable))
  forwarder.emit(fwd, ev, Nil, Nil)
  |> should.equal(Error(forwarder.ForwarderUnavailable))
  // Nothing is reported while no incarnation runs: no process can emit it,
  // and the emitter never reports on its own.
  process.receive(dropped.1, 50) |> should.be_error()

  let assert Ok(started2) = spec.start()
  process.receive(dropped.1, 200)
  |> should.equal(
    Ok(#(forwarder.Dropped(rejected: 0, lost: 0, unavailable: 3), started2.pid)),
  )
  process.receive(dropped.1, 100) |> should.be_error()

  // The count was reset by that report, and capacity is untouched: the one
  // slot still admits a send. Waiting for its delivery before the kill keeps
  // it from being reported as `lost` by the next incarnation.
  let assert Ok(hid) = sinal.handler_id("forwarder-down-delivered")
  let delivered = process.new_subject()
  let assert Ok(delivered_attachment) =
    sinal.observe(hid, ev, fn(_, _) { process.send(delivered, Nil) })
  forwarder.emit(fwd, ev, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(delivered, 200) |> should.equal(Ok(Nil))
  let assert Ok(Nil) = sinal.detach(delivered_attachment)
  kill_and_wait(started2.pid)
  let assert Ok(_started3) = spec.start()
  process.receive(dropped.1, 100) |> should.be_error()

  let assert Ok(Nil) = sinal.detach(dropped.0)
}

// (h2) An unavailable drop that lands after an incarnation has already
// drained its counts (a send that failed to resolve the name just before the
// incarnation registered it) is not held until the next restart: it rides on
// that incarnation's next drop report. No public call can place a drop in
// that window on demand, so this test adds it to the forwarder's own
// unavailable slot directly, then causes a capacity drop.
pub fn late_unavailable_drop_rides_on_the_next_drop_report_test() {
  let name = process.new_name("forwarder-late-unavailable")
  let assert Ok(fwd) = forwarder.new(name, 1)
  let spec = forwarder.supervised(fwd)
  let assert Ok(started) = spec.start()
  let assert Ok(block_ev) =
    sinal.event(
      [atom.create("forwarder_test"), atom.create("late_unavailable")],
      fields.empty(),
      fields.empty(),
    )
  let assert Ok(block_hid) = sinal.handler_id("forwarder-late-unavailable")
  let entered = process.new_subject()
  let assert Ok(_block_attachment) =
    sinal.observe(block_hid, block_ev, fn(_, _) {
      let gate = process.new_subject()
      process.send(entered, gate)
      let assert Ok(Nil) = process.receive(gate, 2000)
      Nil
    })
  let dropped = observe_dropped("forwarder-late-unavailable-dropped", name)

  test_add_get(forwarder_counters(fwd), 3, 1) |> should.equal(1)
  forwarder.emit(fwd, block_ev, Nil, Nil) |> should.equal(Ok(Nil))
  let assert Ok(gate) = process.receive(entered, 200)
  forwarder.emit(fwd, block_ev, Nil, Nil)
  |> should.equal(Error(forwarder.CapacityExceeded))
  process.send(gate, Nil)

  process.receive(dropped.1, 200)
  |> should.equal(
    Ok(#(forwarder.Dropped(rejected: 1, lost: 0, unavailable: 1), started.pid)),
  )
  process.receive(dropped.1, 100) |> should.be_error()
  let assert Ok(Nil) = sinal.detach(dropped.0)
}

@external(erlang, "forwarder_test_ffi", "forwarder_counters")
fn forwarder_counters(forwarder: forwarder.Forwarder) -> TestCounters

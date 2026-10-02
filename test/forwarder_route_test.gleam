//// Routing: an application maps an event-name prefix to a forwarder, and
//// `sinal.emit` follows that mapping, running handlers synchronously when no
//// route matches.
////
//// Routes are node-global, so every test here uses its own top-level prefix
//// and removes the routes it installs.

import gleam/erlang/atom
import gleam/erlang/process
import gleam/list
import gleam/string
import gleeunit/should
import sinal
import sinal/fields
import sinal/forwarder
import sinal/internal/ffi
import sinal/span

fn start(name: String, capacity: Int) -> #(forwarder.Forwarder, process.Pid) {
  let fwd =
    forwarder.new(process.new_name(name)) |> forwarder.with_capacity(capacity)
  let assert Ok(started) = forwarder.supervised(fwd).start()
  #(fwd, started.pid)
}

fn empty_event(name: List(String)) -> sinal.Event(Nil, Nil) {
  sinal.event(name, fields.empty(), fields.empty())
}

fn report_pid(ev: sinal.Event(Nil, Nil)) -> process.Subject(process.Pid) {
  let subject = process.new_subject()
  let _attachment =
    sinal.observe(ev, fn(_, _) { process.send(subject, process.self()) })
  subject
}

// Without a route, `sinal.emit` runs the handler in the caller, finished
// before the call returns, so its message is already in the mailbox (a zero
// timeout finds it).
pub fn unrouted_emit_runs_handlers_in_the_caller_before_returning_test() {
  let ev = empty_event(["route_test_unrouted", "e"])
  let seen = report_pid(ev)

  sinal.emit(ev, Nil, Nil)
  process.receive(seen, 0) |> should.equal(Ok(process.self()))
}

// With a route, the handler runs in the forwarder process, and the emitter
// returns while that handler is still blocked. A synchronous delivery would
// deadlock here: the release is sent only after `emit` returns. After the
// release, one producer's routed events arrive in the order it sent them.
pub fn routed_emit_returns_before_a_blocked_handler_and_keeps_order_test() {
  let prefix = ["route_test_routed"]
  let #(fwd, fwd_pid) = start("route-routed", 64)
  forwarder.route(prefix, fwd)

  let block = empty_event(list.append(prefix, ["block"]))
  let entered = process.new_subject()
  let _block =
    sinal.observe(block, fn(_, _) {
      let gate = process.new_subject()
      process.send(entered, #(gate, process.self()))
      process.receive_forever(gate)
    })

  let order =
    sinal.event(list.append(prefix, ["order"]), fields.int("n"), fields.empty())
  let received = process.new_subject()
  let _order = sinal.observe(order, fn(n, _) { process.send(received, n) })

  sinal.emit(block, Nil, Nil)
  let sequence = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
  list.each(sequence, fn(n) { sinal.emit(order, n, Nil) })

  let assert Ok(#(gate, handler_pid)) = process.receive(entered, 200)
  handler_pid |> should.equal(fwd_pid)
  process.send(gate, Nil)

  list.map(sequence, fn(_) {
    let assert Ok(n) = process.receive(received, 200)
    n
  })
  |> should.equal(sequence)

  forwarder.unroute(prefix)
}

// The longest routed prefix of an event's name selects its forwarder; an
// event outside every routed prefix stays synchronous.
pub fn longest_routed_prefix_selects_the_forwarder_test() {
  let #(broad, broad_pid) = start("route-longest-broad", 8)
  let #(narrow, narrow_pid) = start("route-longest-narrow", 8)
  forwarder.route(["route_test_longest"], broad)
  forwarder.route(["route_test_longest", "tool"], narrow)

  let tool_ev = empty_event(["route_test_longest", "tool", "start"])
  let run_ev = empty_event(["route_test_longest", "run", "start"])
  let other_ev = empty_event(["route_test_other", "tool"])
  let tool_seen = report_pid(tool_ev)
  let run_seen = report_pid(run_ev)
  let other_seen = report_pid(other_ev)

  sinal.emit(tool_ev, Nil, Nil)
  sinal.emit(run_ev, Nil, Nil)
  sinal.emit(other_ev, Nil, Nil)

  process.receive(tool_seen, 200) |> should.equal(Ok(narrow_pid))
  process.receive(run_seen, 200) |> should.equal(Ok(broad_pid))
  process.receive(other_seen, 0) |> should.equal(Ok(process.self()))

  forwarder.unroute(["route_test_longest", "tool"])
  forwarder.unroute(["route_test_longest"])
}

// The empty prefix routes every event that no longer prefix claims.
pub fn empty_prefix_routes_every_event_test() {
  let #(fwd, fwd_pid) = start("route-catch-all", 8)
  forwarder.route([], fwd)

  let ev = empty_event(["route_test_catch_all"])
  let seen = report_pid(ev)
  sinal.emit(ev, Nil, Nil)
  process.receive(seen, 200) |> should.equal(Ok(fwd_pid))

  forwarder.unroute([])
  sinal.emit(ev, Nil, Nil)
  process.receive(seen, 0) |> should.equal(Ok(process.self()))
}

// Routing a prefix again replaces its forwarder; removing the route
// restores synchronous delivery.
pub fn route_replaces_and_unroute_restores_synchronous_delivery_test() {
  let prefix = ["route_test_replace"]
  let #(first, _first_pid) = start("route-replace-first", 8)
  let #(second, second_pid) = start("route-replace-second", 8)
  let ev = empty_event(list.append(prefix, ["e"]))
  let seen = report_pid(ev)

  forwarder.route(prefix, first)
  forwarder.route(prefix, second)
  sinal.emit(ev, Nil, Nil)
  process.receive(seen, 200) |> should.equal(Ok(second_pid))

  forwarder.unroute(prefix)
  sinal.emit(ev, Nil, Nil)
  process.receive(seen, 0) |> should.equal(Ok(process.self()))

  // Removing an absent route is a no-op.
  forwarder.unroute(prefix)
}

// Overflow never blocks the emitter: beyond capacity a routed event is
// dropped, and the forwarder reports the drop from its own process.
pub fn routed_overflow_is_dropped_and_reported_test() {
  let prefix = ["route_test_overflow"]
  let #(fwd, fwd_pid) = start("route-overflow", 1)
  forwarder.route(prefix, fwd)

  let block = empty_event(list.append(prefix, ["block"]))
  let entered = process.new_subject()
  let ran = process.new_subject()
  let _block =
    sinal.observe(block, fn(_, _) {
      process.send(ran, Nil)
      let gate = process.new_subject()
      process.send(entered, gate)
      let assert Ok(Nil) = process.receive(gate, 2000)
      Nil
    })

  let dropped = observe_dropped("route-overflow")

  sinal.emit(block, Nil, Nil)
  let assert Ok(gate) = process.receive(entered, 200)
  sinal.emit(block, Nil, Nil)
  sinal.emit(block, Nil, Nil)

  process.send(gate, Nil)
  process.receive(dropped.1, 500)
  |> should.equal(
    Ok(#(forwarder.Dropped(rejected: 2, lost: 0, unavailable: 0), fwd_pid)),
  )
  // Only the admitted event ran.
  process.receive(ran, 0) |> should.equal(Ok(Nil))
  process.receive(ran, 50) |> should.be_error()

  let assert Ok(Nil) = sinal.detach(dropped.0)
  forwarder.unroute(prefix)
}

// A route whose forwarder is not running drops the event; it never falls
// back to running the handler in the emitter. The drop is counted, not
// silent: the forwarder's first incarnation reports it as `unavailable`
// from its own process.
pub fn route_to_a_stopped_forwarder_drops_instead_of_running_inline_test() {
  let prefix = ["route_test_stopped"]
  let fwd = forwarder.new(process.new_name("route-stopped"))
  forwarder.route(prefix, fwd)
  let dropped = observe_dropped("route-stopped")

  let ev = empty_event(list.append(prefix, ["e"]))
  let seen = report_pid(ev)
  sinal.emit(ev, Nil, Nil)
  process.receive(seen, 50) |> should.be_error()
  process.receive(dropped.1, 0) |> should.be_error()

  let assert Ok(started) = forwarder.supervised(fwd).start()
  process.receive(dropped.1, 200)
  |> should.equal(
    Ok(#(forwarder.Dropped(rejected: 0, lost: 0, unavailable: 1), started.pid)),
  )

  let assert Ok(Nil) = sinal.detach(dropped.0)
  forwarder.unroute(prefix)
}

// A forwarder's drop report is never routed, so counting unavailable drops
// cannot feed itself: with the empty prefix sending every event to a
// forwarder that is down, its report still runs once in its own process when
// it starts, and produces no further drop or report.
pub fn drop_report_is_never_routed_even_by_the_empty_prefix_test() {
  let fwd = forwarder.new(process.new_name("route-no-loop"))
  forwarder.route([], fwd)
  let dropped = observe_dropped("route-no-loop")

  sinal.emit(empty_event(["route_test_no_loop", "e"]), Nil, Nil)

  let assert Ok(started) = forwarder.supervised(fwd).start()
  process.receive(dropped.1, 200)
  |> should.equal(
    Ok(#(forwarder.Dropped(rejected: 0, lost: 0, unavailable: 1), started.pid)),
  )
  process.receive(dropped.1, 100) |> should.be_error()

  let assert Ok(Nil) = sinal.detach(dropped.0)
  forwarder.unroute([])
}

// A span runs in one process: its start and stop events ignore routes, even
// the empty prefix.
pub fn spans_ignore_routes_test() {
  let #(fwd, _pid) = start("route-span", 8)
  forwarder.route(["route_test_span"], fwd)
  let definition =
    span.define(
      ["route_test_span", "work"],
      start_metadata: fields.empty(),
      stop_measurements: fields.empty(),
      stop_metadata: fields.empty(),
    )
  let events = span.events(definition)
  let seen = process.new_subject()
  let start =
    sinal.observe(events.start, fn(_, _) {
      process.send(seen, #("start", process.self()))
    })
  let stop =
    sinal.observe(events.stop, fn(_, _) {
      process.send(seen, #("stop", process.self()))
    })

  span.run(definition, Nil, fn() { span.Completion(Nil, Nil, Nil) })
  process.receive(seen, 0) |> should.equal(Ok(#("start", process.self())))
  process.receive(seen, 0) |> should.equal(Ok(#("stop", process.self())))

  let assert Ok(Nil) = sinal.detach(start)
  let assert Ok(Nil) = sinal.detach(stop)
  forwarder.unroute(["route_test_span"])
}

// `forwarder.emit` targets its forwarder and ignores routes: an event routed
// elsewhere still goes to the forwarder it names, and a refusal is returned.
pub fn owner_emit_ignores_routes_and_returns_the_refusal_test() {
  let #(routed, routed_pid) = start("route-owner-routed", 8)
  let #(owned, owned_pid) = start("route-owner-owned", 8)
  forwarder.route(["route_test_owner"], routed)
  let ev = empty_event(["route_test_owner", "e"])
  let seen = report_pid(ev)

  forwarder.emit(owned, ev, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(seen, 200) |> should.equal(Ok(owned_pid))
  sinal.emit(ev, Nil, Nil)
  process.receive(seen, 200) |> should.equal(Ok(routed_pid))

  let stopped = forwarder.new(process.new_name("route-owner-stopped"))
  forwarder.emit(stopped, ev, Nil, Nil)
  |> should.equal(Error(forwarder.ForwarderUnavailable))
  forwarder.unroute(["route_test_owner"])
}

// Observes `dropped_event` for the forwarder whose name starts with
// `forwarder_name`, recording each report with the pid that emitted it.
fn observe_dropped(
  forwarder_name: String,
) -> #(sinal.Attachment, process.Subject(#(forwarder.Dropped, process.Pid))) {
  let subject = process.new_subject()
  let attachment =
    sinal.observe(forwarder.dropped_event(), fn(report, meta) {
      case string.starts_with(meta.forwarder, forwarder_name) {
        True -> process.send(subject, #(report, process.self()))
        False -> Nil
      }
    })
  #(attachment, subject)
}

// A handler that raises behind a route is isolated by native telemetry in
// the forwarder: the emitter continues, and the forwarder keeps delivering
// later events.
pub fn raising_handler_behind_a_route_never_reaches_the_emitter_test() {
  let prefix = ["route_test_raise"]
  let #(fwd, fwd_pid) = start("route-raise", 8)
  forwarder.route(prefix, fwd)

  let raise = empty_event(list.append(prefix, ["raise"]))
  let _raise = sinal.observe(raise, fn(_, _) { panic as "routed handler" })

  let failure_listener = ffi.to_dynamic(atom.create("route_raise_failure"))
  let failures = process.new_subject()
  let assert Ok(Nil) =
    ffi.telemetry_attach_many(
      failure_listener,
      [
        [
          atom.create("telemetry"),
          atom.create("handler"),
          atom.create("failure"),
        ],
      ],
      fn(_, _, _) { process.send(failures, Nil) },
    )

  let after = empty_event(list.append(prefix, ["after"]))
  let after_seen = report_pid(after)

  sinal.emit(raise, Nil, Nil)
  process.receive(failures, 200) |> should.equal(Ok(Nil))
  sinal.emit(after, Nil, Nil)
  process.receive(after_seen, 200) |> should.equal(Ok(fwd_pid))

  let _ = ffi.telemetry_detach(failure_listener)
  forwarder.unroute(prefix)
}

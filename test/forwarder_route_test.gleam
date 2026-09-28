//// Routing: an application maps an event-name prefix to a forwarder, and a
//// library's `forwarder.emit_routed` follows that mapping, falling back to
//// synchronous `sinal.emit` semantics when no route matches.
////
//// Routes are node-global, so every test here uses its own top-level prefix
//// atom and removes the routes it installs.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/list
import gleam/string
import gleeunit/should
import sinal
import sinal/fields
import sinal/forwarder
import sinal/internal/ffi

fn start(name: String, capacity: Int) -> #(forwarder.Forwarder, process.Pid) {
  let assert Ok(fwd) = forwarder.new(process.new_name(name), capacity)
  let assert Ok(started) = forwarder.supervised(fwd).start()
  #(fwd, started.pid)
}

fn empty_event(name: List(Atom)) -> sinal.Event(Nil, Nil) {
  let assert Ok(ev) = sinal.event(name, fields.empty(), fields.empty())
  ev
}

fn report_pid(
  id: String,
  ev: sinal.Event(Nil, Nil),
) -> process.Subject(process.Pid) {
  let assert Ok(hid) = sinal.handler_id(id)
  let subject = process.new_subject()
  let assert Ok(_attachment) =
    sinal.observe(hid, ev, fn(_, _) { process.send(subject, process.self()) })
  subject
}

// Without a route, `emit_routed` is `sinal.emit`: the handler runs in the
// caller and has finished before the call returns, so its message is already
// in the mailbox (a zero timeout finds it).
pub fn unrouted_emit_runs_handlers_in_the_caller_before_returning_test() {
  let ev = empty_event([atom.create("route_test_unrouted"), atom.create("e")])
  let seen = report_pid("route-unrouted", ev)

  forwarder.emit_routed(ev, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(seen, 0) |> should.equal(Ok(process.self()))
}

// With a route, the handler runs in the forwarder process, and the emitter
// returns while that handler is still blocked. A synchronous delivery would
// deadlock here: the release is sent only after `emit_routed` returns. After
// the release, one producer's routed events arrive in the order it sent them.
pub fn routed_emit_returns_before_a_blocked_handler_and_keeps_order_test() {
  let prefix = [atom.create("route_test_routed")]
  let #(fwd, fwd_pid) = start("route-routed", 64)
  forwarder.route(prefix, fwd)

  let block = empty_event(list.append(prefix, [atom.create("block")]))
  let assert Ok(block_hid) = sinal.handler_id("route-routed-block")
  let entered = process.new_subject()
  let assert Ok(_block) =
    sinal.observe(block_hid, block, fn(_, _) {
      let gate = process.new_subject()
      process.send(entered, #(gate, process.self()))
      process.receive_forever(gate)
    })

  let assert Ok(order) =
    sinal.event(
      list.append(prefix, [atom.create("order")]),
      fields.int(atom.create("n")),
      fields.empty(),
    )
  let assert Ok(order_hid) = sinal.handler_id("route-routed-order")
  let received = process.new_subject()
  let assert Ok(_order) =
    sinal.observe(order_hid, order, fn(n, _) { process.send(received, n) })

  forwarder.emit_routed(block, Nil, Nil) |> should.equal(Ok(Nil))
  let sequence = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
  list.each(sequence, fn(n) {
    forwarder.emit_routed(order, n, Nil) |> should.equal(Ok(Nil))
  })

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
  let top = atom.create("route_test_longest")
  let tool = atom.create("tool")
  let #(broad, broad_pid) = start("route-longest-broad", 8)
  let #(narrow, narrow_pid) = start("route-longest-narrow", 8)
  forwarder.route([top], broad)
  forwarder.route([top, tool], narrow)

  let tool_ev = empty_event([top, tool, atom.create("start")])
  let run_ev = empty_event([top, atom.create("run"), atom.create("start")])
  let other_ev = empty_event([atom.create("route_test_other"), tool])
  let tool_seen = report_pid("route-longest-tool", tool_ev)
  let run_seen = report_pid("route-longest-run", run_ev)
  let other_seen = report_pid("route-longest-other", other_ev)

  forwarder.emit_routed(tool_ev, Nil, Nil) |> should.equal(Ok(Nil))
  forwarder.emit_routed(run_ev, Nil, Nil) |> should.equal(Ok(Nil))
  forwarder.emit_routed(other_ev, Nil, Nil) |> should.equal(Ok(Nil))

  process.receive(tool_seen, 200) |> should.equal(Ok(narrow_pid))
  process.receive(run_seen, 200) |> should.equal(Ok(broad_pid))
  process.receive(other_seen, 0) |> should.equal(Ok(process.self()))

  forwarder.unroute([top, tool])
  forwarder.unroute([top])
}

// The empty prefix routes every routed event that no longer prefix claims.
pub fn empty_prefix_routes_every_routed_event_test() {
  let #(fwd, fwd_pid) = start("route-catch-all", 8)
  forwarder.route([], fwd)

  let ev = empty_event([atom.create("route_test_catch_all")])
  let seen = report_pid("route-catch-all", ev)
  forwarder.emit_routed(ev, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(seen, 200) |> should.equal(Ok(fwd_pid))

  forwarder.unroute([])
  forwarder.emit_routed(ev, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(seen, 0) |> should.equal(Ok(process.self()))
}

// Routing a prefix again replaces its forwarder; removing the route
// restores synchronous delivery.
pub fn route_replaces_and_unroute_restores_synchronous_delivery_test() {
  let prefix = [atom.create("route_test_replace")]
  let #(first, _first_pid) = start("route-replace-first", 8)
  let #(second, second_pid) = start("route-replace-second", 8)
  let ev = empty_event(list.append(prefix, [atom.create("e")]))
  let seen = report_pid("route-replace", ev)

  forwarder.route(prefix, first)
  forwarder.route(prefix, second)
  forwarder.emit_routed(ev, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(seen, 200) |> should.equal(Ok(second_pid))

  forwarder.unroute(prefix)
  forwarder.emit_routed(ev, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(seen, 0) |> should.equal(Ok(process.self()))

  // Removing an absent route is a no-op.
  forwarder.unroute(prefix)
}

// Overflow never blocks the emitter: beyond capacity a routed event is
// rejected, and the forwarder reports the drop from its own process.
pub fn routed_overflow_is_rejected_and_reported_as_dropped_test() {
  let prefix = [atom.create("route_test_overflow")]
  let #(fwd, fwd_pid) = start("route-overflow", 1)
  forwarder.route(prefix, fwd)

  let block = empty_event(list.append(prefix, [atom.create("block")]))
  let assert Ok(block_hid) = sinal.handler_id("route-overflow-block")
  let entered = process.new_subject()
  let assert Ok(_block) =
    sinal.observe(block_hid, block, fn(_, _) {
      let gate = process.new_subject()
      process.send(entered, gate)
      let assert Ok(Nil) = process.receive(gate, 2000)
      Nil
    })

  let assert Ok(dropped_hid) = sinal.handler_id("route-overflow-dropped")
  let dropped = process.new_subject()
  let assert Ok(dropped_attachment) =
    sinal.observe(dropped_hid, forwarder.dropped_event(), fn(report, meta) {
      case string.starts_with(meta.forwarder, "route-overflow") {
        True -> process.send(dropped, #(report, process.self()))
        False -> Nil
      }
    })

  forwarder.emit_routed(block, Nil, Nil) |> should.equal(Ok(Nil))
  let assert Ok(gate) = process.receive(entered, 200)
  forwarder.emit_routed(block, Nil, Nil)
  |> should.equal(Error(forwarder.CapacityExceeded))
  forwarder.emit_routed(block, Nil, Nil)
  |> should.equal(Error(forwarder.CapacityExceeded))

  process.send(gate, Nil)
  process.receive(dropped, 500)
  |> should.equal(Ok(#(forwarder.Dropped(rejected: 2, lost: 0), fwd_pid)))

  let assert Ok(Nil) = sinal.detach(dropped_attachment)
  forwarder.unroute(prefix)
}

// A route whose forwarder is not running drops the event; it never falls
// back to running the handler in the emitter.
pub fn route_to_a_stopped_forwarder_drops_instead_of_running_inline_test() {
  let prefix = [atom.create("route_test_stopped")]
  let assert Ok(fwd) = forwarder.new(process.new_name("route-stopped"), 4)
  forwarder.route(prefix, fwd)

  let ev = empty_event(list.append(prefix, [atom.create("e")]))
  let seen = report_pid("route-stopped", ev)
  forwarder.emit_routed(ev, Nil, Nil)
  |> should.equal(Error(forwarder.ForwarderUnavailable))
  process.receive(seen, 50) |> should.be_error()

  forwarder.unroute(prefix)
}

// A handler that raises behind a route is isolated by native telemetry in
// the forwarder: the emitter still gets `Ok`, and the forwarder keeps
// delivering later events.
pub fn raising_handler_behind_a_route_never_reaches_the_emitter_test() {
  let prefix = [atom.create("route_test_raise")]
  let #(fwd, fwd_pid) = start("route-raise", 8)
  forwarder.route(prefix, fwd)

  let raise = empty_event(list.append(prefix, [atom.create("raise")]))
  let assert Ok(raise_hid) = sinal.handler_id("route-raise-handler")
  let assert Ok(_raise) =
    sinal.observe(raise_hid, raise, fn(_, _) { panic as "routed handler" })

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
      fn(_, _, _, _) { process.send(failures, Nil) },
      ffi.to_dynamic(Nil),
    )

  let after = empty_event(list.append(prefix, [atom.create("after")]))
  let after_seen = report_pid("route-raise-after", after)

  forwarder.emit_routed(raise, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(failures, 200) |> should.equal(Ok(Nil))
  forwarder.emit_routed(after, Nil, Nil) |> should.equal(Ok(Nil))
  process.receive(after_seen, 200) |> should.equal(Ok(fwd_pid))

  let _ = ffi.telemetry_detach(failure_listener)
  forwarder.unroute(prefix)
}

// An encoding failure is reported the same way whether or not a route
// matches, and no handler runs.
pub fn encoding_failure_is_reported_on_both_paths_test() {
  let prefix = [atom.create("route_test_encode")]
  let strict =
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
    sinal.event(list.append(prefix, [atom.create("e")]), strict, fields.empty())
  let expected =
    Error(
      forwarder.ForwardEncodingFailed(fields.FieldEncodeError(
        "negative prohibited",
      )),
    )

  forwarder.emit_routed(ev, -1, Nil) |> should.equal(expected)

  let #(fwd, _pid) = start("route-encode", 1)
  forwarder.route(prefix, fwd)
  forwarder.emit_routed(ev, -1, Nil) |> should.equal(expected)
  forwarder.unroute(prefix)
}

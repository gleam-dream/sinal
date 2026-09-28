//// A bounded, emitter-side forwarder that hands an event off to a dedicated
//// process before any attached handler runs, so a slow or blocked handler
//// stalls the forwarder instead of the producer.
////
//// `sinal.emit` and `sinal.attach`/`sinal.observe` are unaffected by this
//// module; a forwarder is an explicit, additive hop a producer opts into.
////
//// ## Routing
////
//// A library that emits observations but does not own a forwarder calls
//// `emit_routed`. The application decides, per event-name prefix, whether
//// those events go through a forwarder (`route`) or stay synchronous (the
//// default, and what `unroute` restores). The library never chooses at the
//// call site, and an application that routes nothing keeps exactly
//// `sinal.emit` behaviour.
////
//// ## Operational limits
////
//// - **Best-effort delivery.** A capacity-exceeding `emit` is rejected with
////   `CapacityExceeded` and counted as a drop. A forwarder that is not
////   running (not yet started, or mid-restart) rejects with
////   `ForwarderUnavailable`. Neither case blocks or retries.
//// - **Per-producer FIFO, no global order.** Native BEAM message ordering
////   guarantees a single producer's forwarded events are dispatched in the
////   order it sent them. Interleaving across producers is unspecified, as it
////   already is for native telemetry handler order.
//// - **The forwarder is the handler's `self()`.** Attached handlers execute
////   inside the forwarder process, not the caller. Process-dictionary
////   context on the producer is not carried across the hop, and a native
////   telemetry span cannot be forwarded (its start and stop must share one
////   process to measure duration).
//// - **Shutdown does not drain.** Messages still in flight when the
////   forwarder process stops are lost, not delivered. A supervised restart
////   reports that loss: the leftover in-flight count inherited from the
////   previous incarnation is read and reset once the new incarnation starts
////   handling messages, and reported through `dropped_event`.
//// - **`lost` is an approximate upper bound, not an exact count.** `gleam_otp`
////   registers a restarting actor's name before its initialiser runs, so a
////   concurrent `emit` can already resolve to the new incarnation and queue
////   a real Execute message before that incarnation drains the slot it
////   inherited; such a message can be counted as `lost` even though it is
////   still delivered. A kill between a handler finishing and its decrement
////   running has the same effect. The in-flight counter itself never goes
////   negative from this (a floored decrement), so it cannot silently raise
////   capacity — only `lost` can overcount, never the live counter undercount
////   what is truly in flight.
//// - **One `Forwarder` per name.** Each call to `new` allocates its own,
////   independent counters; constructing two `Forwarder` values for the same
////   `process.Name` does not share capacity accounting between them.
//// - **A handler's exit, not just its raise, can take the forwarder down.**
////   Native telemetry catches a handler that raises (`error`/`throw`) and
////   isolates it as usual. A handler that itself links to another process
////   and receives an exit signal, or that is sent an untrappable `kill`,
////   can still terminate the forwarder process — telemetry cannot isolate a
////   process-level exit the way it isolates a raised exception.
//// - **Concurrent emitters may see a spurious, safe rejection near the
////   boundary.** Capacity admission is a single atomic increment-then-check,
////   so it never over-admits; under concurrent load at the boundary it can
////   reject a send that would have fit had it been ordered differently. It
////   never admits past capacity.
//// - **Routed ordering holds per route.** A producer's `emit_routed` events
////   that resolve to the same forwarder are dispatched in the order it sent
////   them, and so are its unrouted ones. Events split across two routes, or
////   across a route change, have no relative order; after an `unroute`, a
////   later synchronous event can run before an earlier forwarded one.
//// - **Routes are node-global, set-up-time values.** They live in
////   `persistent_term`: an emit reads them without locking, and a node with
////   no routes pays one lookup per `emit_routed`. Changing a route is
////   expensive and should happen at application start or shutdown.
//// - **Drop reporting is coalesced, not exhaustive.** Concurrent drops within
////   one `ReportDrops` drain cycle fold into a single `dropped_event`
////   describing how many were rejected, rather than one event per drop.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import sinal.{type Event}
import sinal/fields.{type FieldEncodeError}
import sinal/internal/ffi

/// A bounded forwarding target: a process name to dispatch to and the shared
/// atomics counters tracking in-flight and dropped messages across restarts.
pub opaque type Forwarder {
  Forwarder(name: process.Name(Message), capacity: Int, counters: Counters)
}

/// The forwarder's own message protocol. Never constructed or matched
/// outside this module; producers only ever see `Forwarder` and `emit`.
pub opaque type Message {
  Execute(name: List(Atom), measurements: Dynamic, metadata: Dynamic)
  ReportDrops
  ReportLoss(rejected: Int, lost: Int)
}

pub type ConfigError {
  InvalidCapacity
}

pub type ForwardError {
  ForwardEncodingFailed(FieldEncodeError)
  CapacityExceeded
  ForwarderUnavailable
}

/// Reported once per drain: `rejected` counts capacity drops folded together
/// since the last report, `lost` counts in-flight messages that were still
/// outstanding when the previous incarnation stopped (zero outside of a
/// restart report).
pub type Dropped {
  Dropped(rejected: Int, lost: Int)
}

pub type DroppedMetadata {
  DroppedMetadata(forwarder: String)
}

type Counters

@external(erlang, "sinal_forwarder_ffi", "new_counters")
fn new_counters() -> Counters

@external(erlang, "sinal_forwarder_ffi", "add_get")
fn add_get(counters: Counters, index: Int, delta: Int) -> Int

@external(erlang, "sinal_forwarder_ffi", "exchange")
fn exchange(counters: Counters, index: Int, value: Int) -> Int

@external(erlang, "sinal_forwarder_ffi", "decrement_floor")
fn decrement_floor(counters: Counters, index: Int) -> Int

@external(erlang, "sinal_forwarder_ffi", "try_send")
fn try_send_thunk(thunk: fn() -> Nil) -> Result(Nil, Nil)

@external(erlang, "sinal_forwarder_ffi", "put_route")
fn put_route(prefix: List(Atom), forwarder: Forwarder) -> Nil

@external(erlang, "sinal_forwarder_ffi", "erase_route")
fn erase_route(prefix: List(Atom)) -> Nil

@external(erlang, "sinal_forwarder_ffi", "find_route")
fn find_route(name: List(Atom)) -> Result(Forwarder, Nil)

@external(erlang, "erlang", "atom_to_binary")
fn name_to_string(name: process.Name(a)) -> String

const in_flight_index = 1

const drop_index = 2

/// Allocates a forwarder's shared counters. Starts no process; pair the
/// result with `supervised` to run it.
pub fn new(
  name: process.Name(Message),
  capacity: Int,
) -> Result(Forwarder, ConfigError) {
  case capacity > 0 {
    True -> Ok(Forwarder(name:, capacity:, counters: new_counters()))
    False -> Error(InvalidCapacity)
  }
}

/// Describes the forwarder's process for an OTP supervisor. Restarting under
/// this specification reuses the same counters, so a fresh incarnation can
/// report what the previous one lost.
pub fn supervised(forwarder: Forwarder) -> supervision.ChildSpecification(Nil) {
  supervision.worker(fn() { start_forwarder(forwarder) })
}

/// Drains both counters and, if either held anything, queues the report as
/// the incarnation's own first message rather than emitting it here. Native
/// telemetry handlers for `dropped_event` run synchronously and are
/// arbitrary application code; running them inside the initialiser would
/// count against the 1000ms initialisation timeout and could fail the whole
/// restart. Draining now and reporting from `handle_message` keeps the
/// timeout bounded to the drain itself.
fn start_forwarder(
  forwarder: Forwarder,
) -> Result(actor.Started(Nil), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    let lost = exchange(forwarder.counters, in_flight_index, 0)
    let rejected = exchange(forwarder.counters, drop_index, 0)
    case lost > 0 || rejected > 0 {
      True -> process.send(subject, ReportLoss(rejected, lost))
      False -> Nil
    }
    actor.initialised(forwarder) |> actor.returning(Nil) |> Ok
  })
  |> actor.named(forwarder.name)
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  state: Forwarder,
  message: Message,
) -> actor.Next(Forwarder, Message) {
  case message {
    Execute(name, measurements, metadata) -> {
      ffi.telemetry_execute(name, measurements, metadata)
      let _ = decrement_floor(state.counters, in_flight_index)
      actor.continue(state)
    }
    ReportDrops -> {
      let rejected = exchange(state.counters, drop_index, 0)
      // Guards against a spurious empty `Dropped(0, 0)`: normally this
      // message is only ever sent after `report_drop`'s own 0→1 transition,
      // so `rejected` is always positive here. The one exception is a
      // restart racing this exact send (see the module doc's registration-
      // before-initialiser note and `restart_under_load_never_inflates_
      // capacity_test`'s dropped-event assertion): a fresh incarnation's own
      // startup drain can read and reset this slot before a `ReportDrops`
      // sent to the old incarnation's name resolves to the new one and is
      // processed there, leaving nothing left to report.
      case rejected > 0 {
        True -> emit_dropped(state, rejected, 0)
        False -> Nil
      }
      actor.continue(state)
    }
    ReportLoss(rejected, lost) -> {
      emit_dropped(state, rejected, lost)
      actor.continue(state)
    }
  }
}

fn emit_dropped(forwarder: Forwarder, rejected: Int, lost: Int) -> Nil {
  let assert Ok(Nil) =
    sinal.emit(
      dropped_event(),
      Dropped(rejected:, lost:),
      DroppedMetadata(forwarder: name_to_string(forwarder.name)),
    )
  Nil
}

/// The `[sinal, forwarder, dropped]` event a forwarder emits, from its own
/// process, whenever a drain finds a nonzero rejected or lost count.
pub fn dropped_event() -> Event(Dropped, DroppedMetadata) {
  let assert Ok(ev) =
    sinal.event(
      [atom.create("sinal"), atom.create("forwarder"), atom.create("dropped")],
      dropped_measurements_fields(),
      dropped_metadata_fields(),
    )
  ev
}

fn dropped_measurements_fields() -> fields.Fields(Dropped) {
  let assert Ok(pair) =
    fields.pair(
      fields.int(atom.create("rejected")),
      fields.int(atom.create("lost")),
    )
  fields.imap(pair, fn(p) { Dropped(p.0, p.1) }, fn(d) { #(d.rejected, d.lost) })
}

fn dropped_metadata_fields() -> fields.Fields(DroppedMetadata) {
  fields.imap(
    fields.string(atom.create("forwarder")),
    fn(s) { DroppedMetadata(s) },
    fn(m) { m.forwarder },
  )
}

/// Encodes and forwards an event to run on the forwarder's process instead of
/// the caller's. Returns as soon as the message is handed off (or rejected);
/// it never waits for an attached handler to run.
///
/// Encoding happens before any capacity check, so a rejected encoding never
/// consumes a capacity slot. A capacity-exceeding send is rolled back
/// immediately and folded into the forwarder's next `dropped_event`. A send
/// to a forwarder that is not currently running (not started, or between a
/// crash and its next incarnation) is rescued and reported as
/// `ForwarderUnavailable` rather than propagating a panic.
pub fn emit(
  forwarder: Forwarder,
  event: Event(m, d),
  measurements: m,
  metadata: d,
) -> Result(Nil, ForwardError) {
  use #(name, raw_measurements, raw_metadata) <- result.try(
    sinal.encode_event(event, measurements, metadata)
    |> result.map_error(ForwardEncodingFailed),
  )
  forward(forwarder, name, raw_measurements, raw_metadata)
}

/// Routes every `emit_routed` event whose name starts with `prefix` through
/// `forwarder`, for the whole node. The empty prefix matches every event;
/// when several routed prefixes match, the longest wins. Routing a prefix
/// again replaces its forwarder.
///
/// This is application setup, like attaching a handler: call it once the
/// forwarder is supervised and before the routed library emits. Changing a
/// route is expensive (routes live in `persistent_term`), so do not route
/// per request. `sinal.emit` and `forwarder.emit` never consult routes.
pub fn route(prefix: List(Atom), forwarder: Forwarder) -> Nil {
  put_route(prefix, forwarder)
}

/// Removes the route of exactly `prefix`, if there is one. Events it
/// matched fall back to a shorter routed prefix, or to synchronous
/// delivery. Events already handed to its forwarder are still delivered
/// there, so they can run after later, now synchronous, events of the same
/// producer.
pub fn unroute(prefix: List(Atom)) -> Nil {
  erase_route(prefix)
}

/// Emits an event the way the application routed its name: through the
/// forwarder of the longest routed prefix (exactly `emit`), or, when no route
/// matches, synchronously in the caller (exactly `sinal.emit`).
///
/// This is the call for a library that emits observations but does not own
/// the forwarder. By using it, the library accepts that its handlers may run
/// in another process: it must not rely on the caller's process dictionary,
/// and it cannot carry a native span.
///
/// A routed event is never delivered inline as a fallback. When its
/// forwarder is full (`CapacityExceeded`, counted in `dropped_event`) or not
/// running (`ForwarderUnavailable`, reported only in this result), the event
/// is dropped and the caller continues. `ForwardEncodingFailed` is returned
/// on either path, and no handler runs.
///
/// Handler failures never reach the caller on either path: native telemetry
/// detaches a handler that raises, and a handler exit that takes the
/// forwarder down loses its in-flight events, which the restarted forwarder
/// reports as `Dropped(lost:)`.
pub fn emit_routed(
  event: Event(m, d),
  measurements: m,
  metadata: d,
) -> Result(Nil, ForwardError) {
  use #(name, raw_measurements, raw_metadata) <- result.try(
    sinal.encode_event(event, measurements, metadata)
    |> result.map_error(ForwardEncodingFailed),
  )
  case find_route(name) {
    Ok(forwarder) -> forward(forwarder, name, raw_measurements, raw_metadata)
    Error(Nil) -> {
      ffi.telemetry_execute(name, raw_measurements, raw_metadata)
      Ok(Nil)
    }
  }
}

fn forward(
  forwarder: Forwarder,
  name: List(Atom),
  raw_measurements: Dynamic,
  raw_metadata: Dynamic,
) -> Result(Nil, ForwardError) {
  let in_flight = add_get(forwarder.counters, in_flight_index, 1)
  case in_flight > forwarder.capacity {
    True -> {
      let _ = decrement_floor(forwarder.counters, in_flight_index)
      report_drop(forwarder)
      Error(CapacityExceeded)
    }
    False ->
      case
        try_send_thunk(fn() {
          process.send(
            process.named_subject(forwarder.name),
            Execute(name, raw_measurements, raw_metadata),
          )
        })
      {
        Ok(Nil) -> Ok(Nil)
        Error(Nil) -> {
          let _ = decrement_floor(forwarder.counters, in_flight_index)
          Error(ForwarderUnavailable)
        }
      }
  }
}

/// Increments the drop slot and, only for the sender whose increment moved it
/// from 0 to 1, notifies the forwarder once. Concurrent drops within the same
/// drain cycle accumulate on the counter without sending a second message, so
/// the forwarder reports one coalesced `dropped_event` per cycle rather than
/// one per drop. This send is best-effort and uncounted: it never touches the
/// in-flight slot or reports its own failure.
///
/// This guard and `handle_message`'s `ReportDrops` recheck both sit between
/// a drop storm and a duplicate report, but they protect different things:
/// this one bounds how many `ReportDrops` messages a drop storm ever queues
/// on the forwarder (`concurrent_drops_queue_single_report_message_test`
/// reads the mailbox directly to prove it); the receiver-side recheck
/// guards a single, separate race (see its own comment). Removing either one
/// alone does not change any emitted `dropped_event`'s content under normal
/// operation, because the other keeps the emitted stream correct on its
/// own — the mailbox-length test above is what makes this guard's own
/// contribution observable.
fn report_drop(forwarder: Forwarder) -> Nil {
  case add_get(forwarder.counters, drop_index, 1) {
    1 -> {
      let _ =
        try_send_thunk(fn() {
          process.send(process.named_subject(forwarder.name), ReportDrops)
        })
      Nil
    }
    _ -> Nil
  }
}

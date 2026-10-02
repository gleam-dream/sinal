//// A bounded forwarder: a process that runs the handlers of the events
//// handed to it, so a slow or blocked handler stalls the forwarder instead
//// of the emitter.
////
//// ## Isolating a library's events
////
//// A library emits with `sinal.emit`. The application decides, per
//// event-name prefix, whether those events run synchronously (the default)
//// or in a forwarder. It supervises one forwarder and routes the library's
//// prefix to it, once, at start:
////
//// ```gleam
//// import gleam/erlang/process
//// import gleam/otp/static_supervisor as supervisor
//// import sinal/forwarder
////
//// pub fn start(name: process.Name(forwarder.Message)) {
////   let observations = forwarder.new(name)
////   let assert Ok(_) =
////     supervisor.new(supervisor.OneForOne)
////     |> supervisor.add(forwarder.supervised(observations))
////     |> supervisor.start
////   forwarder.route(["http_gun"], observations)
//// }
//// ```
////
//// Every `sinal.emit` of an event whose name starts with `http_gun` then
//// returns as soon as the event is handed off. A package that owns its
//// forwarder (one per database, say) calls `forwarder.emit` instead, which
//// returns the `Refusal` when the event is dropped.
////
//// ## Operational limits
////
//// - **Best-effort delivery.** A send beyond capacity (1,024 events by
////   default, queued plus executing) is refused with `CapacityExceeded` and
////   counted as `rejected`. A send to a forwarder that is not running (not
////   yet started, or mid-restart) is refused with `ForwarderUnavailable` and
////   counted as `unavailable`. Neither blocks or retries, and a routed event
////   never falls back to inline delivery.
//// - **Per-producer FIFO, no global order.** A single producer's forwarded
////   events run in the order it sent them. Interleaving across producers is
////   unspecified, as it already is for native telemetry handler order.
//// - **The forwarder is the handler's `self()`.** Handlers run inside the
////   forwarder process. Process-dictionary context on the producer is not
////   carried across the hop, and a native span cannot be forwarded (its
////   start and stop must share one process to measure duration); spans and
////   this module's own drop report ignore routes.
//// - **Shutdown does not drain.** Pending events are lost when the process
////   stops. A restart takes a best-effort snapshot of the in-flight count
////   and reports it as `lost`. This count is not a delivery receipt.
//// - **Capacity belongs to one incarnation.** Each running process owns a
////   one-row named ETS table pairing its event subject with its capacity
////   and fresh admission counters, published after initialisation. Before
////   that, producers receive `ForwarderUnavailable`. A delayed producer
////   keeps the old subject and counters; it cannot enqueue into the
////   replacement. The table's name is the forwarder's process name in the
////   separate ETS namespace; a pre-existing ETS table of that name, or a
////   capacity below 1, makes the start fail with `InitFailed`.
//// - **One set of counters per name.** The drop counters live in
////   `persistent_term` under the forwarder's process name, so every
////   `Forwarder` value built from one `process.Name` shares them. Create
////   the name once at application start, never per request: each name
////   keeps its counters for the life of the node.
//// - **A handler's exit, not just its raise, can take the forwarder down.**
////   Native telemetry isolates a handler that raises. A handler that links
////   to another process and receives an exit signal, or is sent `kill`, can
////   still stop the forwarder.
//// - **Concurrent emitters may see a spurious, safe rejection near the
////   boundary.** Admission is a single atomic increment-then-check: it
////   never admits past capacity, but under concurrent load it can reject a
////   send that would have fit under a different ordering.
//// - **Routed ordering holds per route.** A producer's events that resolve
////   to the same forwarder keep its send order, and so do its unrouted
////   ones. Events split across routes, or across a route change, have no
////   relative order.
//// - **Routes are node-global, set-up-time values.** They live in
////   `persistent_term`: an emit reads them without locking, and a node with
////   no routes pays one lookup per `sinal.emit`. Changing a route is
////   expensive and belongs at application start and shutdown.
////
//// ## When drops are reported
////
//// The three counts survive every incarnation. Only a running incarnation
//// reports them, as `dropped_event` from its own process, and each report
//// resets exactly the counts it carries:
////
//// - **When an incarnation starts**, it drains all three counts and
////   reports them, if any is nonzero. Unavailable drops made while it was
////   down arrive here.
//// - **After a drop while it runs**, the next drain reports `rejected` and
////   `unavailable` together (`lost` is zero outside a start). Concurrent
////   drops in one drain fold into one report.
//// - **If no incarnation starts again**, the counts are never reported.
////   The `ForwarderUnavailable` refusal is the only signal meanwhile.
//// - **A report can be lost with its incarnation**, if it is stopped
////   before handling the report it queued at start.
//// - **Reports never loop.** A drop report is emitted directly, never
////   through a route, so reporting a drop never causes one.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import sinal.{type Event}
import sinal/fields.{type Fields}
import sinal/internal/ffi
import sinal/internal/name as grammar
import sinal/internal/route

/// The capacity of a forwarder built with `new`: queued plus executing
/// events.
pub const default_capacity = 1024

/// A forwarder's process name, capacity and shared drop counters. Build it
/// with `new`, run it with `supervised`.
pub opaque type Forwarder {
  Forwarder(name: process.Name(Message), capacity: Int, counters: Counters)
}

/// The forwarder process's message type, needed only to create its
/// `process.Name`.
pub opaque type Message {
  Execute(name: List(Atom), measurements: Dynamic, metadata: Dynamic)
  ReportDrops
  ReportStartDrops(Dropped)
}

/// Why `emit` dropped an event. The union is closed.
pub type Refusal {
  /// The forwarder already holds its capacity of events.
  CapacityExceeded
  /// No incarnation of the forwarder is running.
  ForwarderUnavailable
}

/// Measurements of `dropped_event`, one best-effort diagnostic report.
/// Read it by label; sinal may add fields.
///
/// - `rejected`: sends refused with `CapacityExceeded`.
/// - `lost`: admitted events still in flight when the previous incarnation
///   stopped (zero outside the report an incarnation makes when it starts).
/// - `unavailable`: sends refused with `ForwarderUnavailable`.
pub type Dropped {
  Dropped(rejected: Int, lost: Int, unavailable: Int)
}

/// Metadata of `dropped_event`: the forwarder's process name.
pub type DroppedMetadata {
  DroppedMetadata(forwarder: String)
}

type Counters

type Target {
  Target(subject: process.Subject(Message), capacity: Int, slots: Counters)
}

type Running {
  Running(forwarder: Forwarder, slots: Counters)
}

@external(erlang, "sinal_forwarder_ffi", "publish_target")
fn publish_target(
  name: process.Name(Message),
  target: Target,
) -> Result(Nil, Nil)

@external(erlang, "sinal_forwarder_ffi", "find_target")
fn find_target(name: process.Name(Message)) -> Result(Target, Nil)

@external(erlang, "sinal_forwarder_ffi", "new_counters")
fn new_counters() -> Counters

@external(erlang, "sinal_forwarder_ffi", "shared_counters")
fn shared_counters(name: process.Name(Message)) -> Counters

@external(erlang, "sinal_forwarder_ffi", "add_get")
fn add_get(counters: Counters, index: Int, delta: Int) -> Int

@external(erlang, "sinal_forwarder_ffi", "exchange")
fn exchange(counters: Counters, index: Int, value: Int) -> Int

@external(erlang, "sinal_forwarder_ffi", "decrement_floor")
fn decrement_floor(counters: Counters, index: Int) -> Int

@external(erlang, "erlang", "atom_to_binary")
fn name_to_string(name: process.Name(a)) -> String

@external(erlang, "sinal_ffi", "event_parts")
fn event_parts(event: Event(m, d)) -> #(List(Atom), Fields(m), Fields(d))

const in_flight_index = 1

const drop_index = 2

const unavailable_index = 3

/// Describes a forwarder with the default capacity of 1,024 events. Starts
/// no process; pair it with `supervised`. Every `Forwarder` built from one
/// `name` shares its drop counters.
pub fn new(name: process.Name(Message)) -> Forwarder {
  Forwarder(name:, capacity: default_capacity, counters: shared_counters(name))
}

/// Sets how many events the forwarder holds, queued plus executing. A
/// value below 1 makes the start fail with `InitFailed`.
pub fn with_capacity(forwarder: Forwarder, capacity: Int) -> Forwarder {
  Forwarder(..forwarder, capacity:)
}

/// Describes the forwarder's process for an OTP supervisor. Drop counts
/// survive a restart; admission counters and the event subject do not.
pub fn supervised(
  forwarder: Forwarder,
) -> supervision.ChildSpecification(Forwarder) {
  supervision.worker(fn() { start_forwarder(forwarder) })
}

/// Initialise diagnostics and fresh admission slots before publishing a target.
/// User handlers run only from handle_message, outside actor initialisation.
fn start_forwarder(
  forwarder: Forwarder,
) -> Result(actor.Started(Forwarder), actor.StartError) {
  actor.new_with_initialiser(1000, fn(subject) {
    use Nil <- result.try(case forwarder.capacity >= 1 {
      True -> Ok(Nil)
      False ->
        Error(
          "sinal/forwarder: capacity must be at least 1, got "
          <> int.to_string(forwarder.capacity),
        )
    })
    let slots = new_counters()
    let events = process.new_subject()
    let lost = exchange(forwarder.counters, in_flight_index, 0)
    let rejected = exchange(forwarder.counters, drop_index, 0)
    let unavailable = exchange(forwarder.counters, unavailable_index, 0)
    use Nil <- result.try(
      publish_target(
        forwarder.name,
        Target(events, capacity: forwarder.capacity, slots:),
      )
      |> result.map_error(fn(_) { "forwarder target table already exists" }),
    )
    case lost > 0 || rejected > 0 || unavailable > 0 {
      True ->
        process.send(
          subject,
          ReportStartDrops(Dropped(rejected:, lost:, unavailable:)),
        )
      False -> Nil
    }
    actor.initialised(Running(forwarder, slots))
    |> actor.selecting(
      process.new_selector()
      |> process.select(subject)
      |> process.select(events),
    )
    |> actor.returning(forwarder)
    |> Ok
  })
  |> actor.named(forwarder.name)
  |> actor.on_message(handle_message)
  |> actor.start
}

fn handle_message(
  state: Running,
  message: Message,
) -> actor.Next(Running, Message) {
  let forwarder = state.forwarder
  case message {
    Execute(name, measurements, metadata) -> {
      ffi.telemetry_execute(name, measurements, metadata)
      let _ = decrement_floor(state.slots, in_flight_index)
      let _ = decrement_floor(forwarder.counters, in_flight_index)
      actor.continue(state)
    }
    ReportDrops -> {
      let _ = exchange(state.slots, drop_index, 0)
      let rejected = exchange(forwarder.counters, drop_index, 0)
      let unavailable = exchange(forwarder.counters, unavailable_index, 0)
      case rejected > 0 || unavailable > 0 {
        True ->
          emit_dropped(forwarder, Dropped(rejected:, lost: 0, unavailable:))
        False -> Nil
      }
      actor.continue(state)
    }
    ReportStartDrops(dropped) -> {
      emit_dropped(forwarder, dropped)
      actor.continue(state)
    }
  }
}

/// Emits the report directly, never through a route, so no route (not even
/// `[]`) can send it back through a forwarder.
fn emit_dropped(forwarder: Forwarder, dropped: Dropped) -> Nil {
  let #(name, measurements, metadata) = event_parts(dropped_event())
  ffi.telemetry_execute(
    name,
    fields.encode(measurements, dropped),
    fields.encode(
      metadata,
      DroppedMetadata(forwarder: name_to_string(forwarder.name)),
    ),
  )
}

/// The `[sinal, forwarder, dropped]` event a forwarder emits from its own
/// process when a drain finds a nonzero count. Its measurements are the
/// integer keys `rejected`, `lost` and `unavailable`; its metadata is the
/// forwarder's name under `forwarder`. It is synchronous and never routed.
pub fn dropped_event() -> Event(Dropped, DroppedMetadata) {
  sinal.event(
    ["sinal", "forwarder", "dropped"],
    {
      use rejected <- fields.include(fields.int("rejected"), get: fn(d) {
        d.rejected
      })
      use lost <- fields.include(fields.int("lost"), get: fn(d) { d.lost })
      use unavailable <- fields.include(fields.int("unavailable"), get: fn(d) {
        d.unavailable
      })
      fields.success(Dropped(rejected:, lost:, unavailable:))
    },
    {
      use forwarder <- fields.include(fields.string("forwarder"), get: fn(m) {
        m.forwarder
      })
      fields.success(DroppedMetadata(forwarder:))
    },
  )
}

/// Hands an event to this forwarder, ignoring routes, and returns as soon
/// as it is handed off or refused; it never waits for a handler. A refused
/// event is dropped and counted in the forwarder's next `dropped_event`.
/// Use it in a package that owns its forwarder; a library that does not
/// calls `sinal.emit` and lets the application route it.
pub fn emit(
  forwarder: Forwarder,
  event: Event(m, d),
  measurements: m,
  metadata: d,
) -> Result(Nil, Refusal) {
  let #(name, measurement_fields, metadata_fields) = event_parts(event)
  forward(
    forwarder,
    name,
    fields.encode_for_emit(
      measurement_fields,
      measurements,
      caller: "sinal/forwarder.emit",
      event: fn() { list.map(name, atom.to_string) },
    ),
    fields.encode_for_emit(
      metadata_fields,
      metadata,
      caller: "sinal/forwarder.emit",
      event: fn() { list.map(name, atom.to_string) },
    ),
  )
}

/// Sends every `sinal.emit` event whose name starts with `prefix` through
/// `forwarder`, for the whole node. The empty prefix matches every event;
/// when several prefixes match, the longest wins. Routing a prefix again
/// replaces its forwarder.
///
/// This is application setup, like attaching a handler: call it once the
/// forwarder is supervised. Changing a route is expensive (routes live in
/// `persistent_term`), so do not route per request.
///
/// Panics when a segment of `prefix` breaks the name grammar.
pub fn route(prefix: List(String), forwarder: Forwarder) -> Nil {
  route.put(prefix_atoms(prefix, "sinal/forwarder.route"), fn(name, m, d) {
    let _ = forward(forwarder, name, m, d)
    Nil
  })
}

/// Removes the route of exactly `prefix`, if there is one. Events it
/// matched fall back to a shorter routed prefix, or to synchronous
/// delivery. Events already handed to its forwarder are still delivered
/// there, so they can run after later, now synchronous, events.
pub fn unroute(prefix: List(String)) -> Nil {
  route.erase(prefix_atoms(prefix, "sinal/forwarder.unroute"))
}

/// Describes a refusal for logs.
pub fn describe_refusal(refusal: Refusal) -> String {
  case refusal {
    CapacityExceeded -> "the forwarder is at capacity"
    ForwarderUnavailable -> "the forwarder is not running"
  }
}

fn prefix_atoms(prefix: List(String), caller: String) -> List(Atom) {
  list.map(prefix, fn(segment) {
    grammar.to_atom(segment, caller:, what: "name segment")
  })
}

fn forward(
  forwarder: Forwarder,
  name: List(Atom),
  raw_measurements: Dynamic,
  raw_metadata: Dynamic,
) -> Result(Nil, Refusal) {
  use target <- result.try(
    find_target(forwarder.name)
    |> result.map_error(fn(_) {
      report_drop(forwarder, unavailable_index)
      ForwarderUnavailable
    }),
  )
  let in_flight = add_get(target.slots, in_flight_index, 1)
  case in_flight > target.capacity {
    True -> {
      let _ = decrement_floor(target.slots, in_flight_index)
      report_drop(forwarder, drop_index)
      Error(CapacityExceeded)
    }
    False -> {
      let _ = add_get(forwarder.counters, in_flight_index, 1)
      process.send(
        target.subject,
        Execute(name, raw_measurements, raw_metadata),
      )
      Ok(Nil)
    }
  }
}

/// Increments a drop slot and coalesces one notice per running incarnation.
/// The flag is cleared before draining counts, so racing drops can schedule the
/// next notice. The direct subject and flag belong to the same incarnation:
/// delayed notifications cannot cross a restart or accumulate in its successor.
/// Without a published target the counters remain for a subsequent drain.
fn report_drop(forwarder: Forwarder, index: Int) -> Nil {
  let _ = add_get(forwarder.counters, index, 1)
  case find_target(forwarder.name) {
    Error(Nil) -> Nil
    Ok(target) ->
      case exchange(target.slots, drop_index, 1) {
        0 -> process.send(target.subject, ReportDrops)
        _ -> Nil
      }
  }
}

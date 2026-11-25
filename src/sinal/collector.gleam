//// A bounded collector: the most recent entries built from the events an
//// application observes, kept in memory for a test or a small
//// application to read back.
////
//// The application chooses the entry type and says how each event becomes
//// an entry. The collector's supervised process attaches the handlers and
//// owns the storage:
////
//// ```gleam
//// import gleam/erlang/process
//// import gleam/otp/static_supervisor as supervisor
//// import sinal/collector
////
//// pub fn start(name: process.Name(collector.Message(String))) {
////   let recent = collector.new(name) |> collector.with_capacity(256)
////   let assert Ok(_) =
////     supervisor.new(supervisor.OneForOne)
////     |> supervisor.add(
////       collector.supervised(recent, [
////         collector.source(finished, fn(duration_ms, route) {
////           route <> " took " <> int.to_string(duration_ms) <> " ms"
////         }),
////       ]),
////     )
////     |> supervisor.start
////   recent
//// }
//// ```
////
//// `collector.entries(recent)` then returns at most 256 entries, oldest
//// first. A library can export a list of `Source` values for its events,
//// so an application collects all of them with one line.
////
//// ## Operational limits
////
//// - **Bounded by entry count.** The collector keeps the newest `capacity`
////   entries (1,024 by default) and overwrites the oldest. `recorded`
////   minus the number of retained entries is how many were overwritten.
////   The size of one entry is the application's choice and is not bounded.
//// - **No queue.** A handler writes its entry to the collector's table
////   from the process that runs the handler (the emitter, or the forwarder
////   for a routed event) and copies the entry once. Nothing accumulates in
////   a mailbox, and a slow reader delays no writer.
//// - **Best-effort order.** Entries are ordered by a shared sequence
////   number. Writers that lap each other within one capacity of entries
////   can leave an older entry in place of a newer one; choose a capacity
////   well above the number of concurrent emitters.
//// - **Diagnostic, not durable.** Entries belong to one incarnation of the
////   process: a restart starts empty, and without a running collector an
////   entry is discarded. The collector exports nothing, aggregates nothing
////   and is not a delivery receipt.
//// - **Handlers outlive a restart.** Each source is attached under an id
////   derived from the collector's name and its position in the list, so a
////   restarted collector finds its handlers attached and attaches only the
////   missing ones. `detach` removes them. A handler that telemetry removed
////   after its function raised is attached again by the next restart.
//// - **One name, one table.** The table's name is the collector's process
////   name in the ETS namespace; a pre-existing ETS table of that name, or
////   a capacity below 1, makes the start fail with `InitFailed`. Create
////   the name once at application start.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import sinal.{type Event, type Subscription}

/// The capacity of a collector built with `new`.
pub const default_capacity = 1024

/// A collector's process name and capacity. Build it with `new`, run it
/// with `supervised`.
pub opaque type Collector(entry) {
  Collector(name: process.Name(Message(entry)), capacity: Int)
}

/// The collector process's message type, needed only to create its
/// `process.Name`. The process receives no messages; the type ties a name
/// to one entry type.
pub type Message(entry)

/// How one or more events become entries. Build it with `source` or
/// `source_with`.
pub opaque type Source(entry) {
  Source(subscribe: fn(fn(entry) -> Nil) -> Subscription)
}

@external(erlang, "sinal_collector_ffi", "create")
fn create(name: process.Name(Message(entry)), capacity: Int) -> Result(Nil, Nil)

@external(erlang, "sinal_collector_ffi", "record")
fn ffi_record(name: process.Name(Message(entry)), entry: entry) -> Nil

@external(erlang, "sinal_collector_ffi", "entries")
fn ffi_entries(name: process.Name(Message(entry))) -> List(entry)

@external(erlang, "sinal_collector_ffi", "recorded")
fn ffi_recorded(name: process.Name(Message(entry))) -> Int

@external(erlang, "sinal_collector_ffi", "detach_handlers")
fn detach_handlers(prefix: String) -> Nil

@external(erlang, "erlang", "atom_to_binary")
fn name_to_string(name: process.Name(a)) -> String

/// Describes a collector with the default capacity of 1,024 entries.
/// Starts no process; pair it with `supervised`.
pub fn new(name: process.Name(Message(entry))) -> Collector(entry) {
  Collector(name:, capacity: default_capacity)
}

/// Sets how many entries the collector keeps. A value below 1 makes the
/// start fail with `InitFailed`.
pub fn with_capacity(
  collector: Collector(entry),
  capacity: Int,
) -> Collector(entry) {
  Collector(..collector, capacity:)
}

/// Turns each occurrence of `event` into one entry.
///
/// `to_entry` runs in the process that runs the handler, on every
/// occurrence, so keep it short and total: when it raises, telemetry
/// removes the handler. A native map that does not decode skips that
/// occurrence, as `sinal.subscription` describes.
pub fn source(
  event: Event(m, d),
  to_entry: fn(m, d) -> entry,
) -> Source(entry) {
  Source(fn(record) {
    sinal.subscription(event, fn(measurements, metadata) {
      record(to_entry(measurements, metadata))
    })
  })
}

/// Builds the subscription from the collector's `record` function, for a
/// `sinal.handler` over several events or a handler that records only some
/// occurrences. The collector replaces the subscription's id.
pub fn source_with(
  subscribe: fn(fn(entry) -> Nil) -> Subscription,
) -> Source(entry) {
  Source(subscribe)
}

/// Describes the collector's process for an OTP supervisor. The process
/// creates the storage and attaches `sources`; entries do not survive a
/// restart.
pub fn supervised(
  collector: Collector(entry),
  sources: List(Source(entry)),
) -> supervision.ChildSpecification(Collector(entry)) {
  supervision.worker(fn() { start_collector(collector, sources) })
}

fn start_collector(
  collector: Collector(entry),
  sources: List(Source(entry)),
) -> Result(actor.Started(Collector(entry)), actor.StartError) {
  actor.new_with_initialiser(5000, fn(_subject) {
    use Nil <- result.try(case collector.capacity >= 1 {
      True -> Ok(Nil)
      False ->
        Error(
          "sinal/collector: capacity must be at least 1, got "
          <> int.to_string(collector.capacity),
        )
    })
    use Nil <- result.try(
      create(collector.name, collector.capacity)
      |> result.replace_error("sinal/collector: the table already exists"),
    )
    list.index_map(sources, fn(source, index) {
      // `AlreadyExists` means a previous incarnation attached this source.
      // Its handler writes by name, so it serves this incarnation too.
      let _ =
        source.subscribe(record(collector, _))
        |> sinal.with_id(id_prefix(collector) <> int.to_string(index))
        |> sinal.attach
      Nil
    })
    actor.initialised(Nil)
    |> actor.returning(collector)
    |> Ok
  })
  |> actor.named(collector.name)
  |> actor.on_message(fn(state, _message: Message(entry)) {
    actor.continue(state)
  })
  |> actor.start
}

fn id_prefix(collector: Collector(entry)) -> String {
  "sinal/collector:" <> name_to_string(collector.name) <> ":"
}

/// Adds one entry, overwriting the oldest when the collector is full. It
/// runs in the caller, never blocks on the collector's process and never
/// raises; without a running collector the entry is discarded.
pub fn record(collector: Collector(entry), entry: entry) -> Nil {
  ffi_record(collector.name, entry)
}

/// The retained entries, oldest first: at most the collector's capacity.
/// Empty when the collector is not running.
pub fn entries(collector: Collector(entry)) -> List(entry) {
  ffi_entries(collector.name)
}

/// How many entries the running incarnation was handed, including those
/// already overwritten. Zero when the collector is not running.
pub fn recorded(collector: Collector(entry)) -> Int {
  ffi_recorded(collector.name)
}

/// Detaches the handlers of the collector's sources, for an application
/// that stops its collector for good. Stopping the process alone leaves
/// them attached, discarding every entry.
pub fn detach(collector: Collector(entry)) -> Nil {
  detach_handlers(id_prefix(collector))
}

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/otp/static_supervisor as supervisor
import gleeunit/should
import sinal
import sinal/collector.{type Collector}
import sinal/fields

fn start(
  label: String,
  capacity: Int,
  sources: List(collector.Source(entry)),
) -> #(Collector(entry), Running(entry)) {
  let name = process.new_name(label)
  let recent = collector.new(name) |> collector.with_capacity(capacity)
  let assert Ok(started) =
    supervisor.new(supervisor.OneForOne)
    |> supervisor.add(collector.supervised(recent, sources))
    |> supervisor.start
  #(recent, Running(supervisor: started.pid, name:))
}

type Running(entry) {
  Running(supervisor: process.Pid, name: process.Name(collector.Message(entry)))
}

@external(erlang, "collector_test_ffi", "trace_receives")
fn trace_receives(pid: process.Pid) -> Nil

@external(erlang, "erlang", "atom_to_binary")
fn name_to_string(name: process.Name(a)) -> String

@external(erlang, "collector_test_ffi", "handler_count")
fn handler_count(event: List(String)) -> Int

@external(erlang, "collector_test_ffi", "terminate_child")
fn terminate_child(supervisor: process.Pid) -> Nil

@external(erlang, "owner_test_ffi", "janitor_pid")
fn janitor() -> process.Pid

@external(erlang, "owner_test_ffi", "await_down_received")
fn await_down_received(pid: process.Pid, owner: process.Pid) -> Result(Nil, Nil)

@external(erlang, "owner_test_ffi", "sync")
fn sync(pid: process.Pid) -> Nil

@external(erlang, "collector_test_ffi", "await_restart")
fn await_restart(
  supervisor: process.Pid,
  child: process.Pid,
) -> Result(Nil, Nil)

fn count_event(name: String) -> sinal.Event(Int, String) {
  sinal.event(["collector_test", name], fields.int("n"), fields.string("who"))
}

fn emit_range(event: sinal.Event(Int, String), from: Int, to: Int) -> Nil {
  case from > to {
    True -> Nil
    False -> {
      sinal.emit(event, from, "w")
      emit_range(event, from + 1, to)
    }
  }
}

pub fn collects_entries_from_several_events_in_order_test() {
  let first = count_event("first")
  let second = count_event("second")
  let #(recent, _) =
    start("collector-order", 8, [
      collector.source(first, fn(n, who) { "first " <> who <> int.to_string(n) }),
      collector.source(second, fn(n, who) {
        "second " <> who <> int.to_string(n)
      }),
    ])
  sinal.emit(first, 1, "a")
  sinal.emit(second, 2, "b")
  sinal.emit(first, 3, "c")
  collector.entries(recent)
  |> should.equal(["first a1", "second b2", "first c3"])
  collector.recorded(recent) |> should.equal(3)
}

pub fn keeps_only_the_newest_capacity_entries_test() {
  let event = count_event("bounded")
  let #(recent, _) =
    start("collector-bounded", 4, [collector.source(event, fn(n, _) { n })])
  emit_range(event, 1, 1000)
  collector.entries(recent) |> should.equal([997, 998, 999, 1000])
  collector.recorded(recent) |> should.equal(1000)
}

pub fn a_restarted_collector_starts_empty_and_keeps_collecting_test() {
  let event = count_event("restart")
  let #(recent, running) =
    start("collector-restart", 4, [collector.source(event, fn(n, _) { n })])
  sinal.emit(event, 1, "w")
  collector.entries(recent) |> should.equal([1])

  let assert Ok(pid) = process.named(running.name)
  trace_receives(running.supervisor)
  process.kill(pid)
  let assert Ok(Nil) = await_restart(running.supervisor, pid)
  let assert Ok(replacement) = process.named(running.name)
  { replacement == pid } |> should.equal(False)

  collector.entries(recent) |> should.equal([])
  sinal.emit(event, 2, "w")
  // The replacement took over the source's id: the entry is recorded once.
  collector.entries(recent) |> should.equal([2])
  collector.recorded(recent) |> should.equal(1)
}

// The collector's process owns its sources' handlers, so stopping it
// detaches them; there is nothing to detach by hand.
pub fn stopping_the_collector_detaches_its_handlers_test() {
  let event = count_event("stopped")
  let #(recent, running) =
    start("collector-stopped", 4, [collector.source(event, fn(n, _) { n })])
  sinal.emit(event, 1, "w")
  collector.entries(recent) |> should.equal([1])
  handler_count(["collector_test", "stopped"]) |> should.equal(1)

  let assert Ok(pid) = process.named(running.name)
  let janitor = janitor()
  trace_receives(janitor)
  terminate_child(running.supervisor)
  let assert Ok(Nil) = await_down_received(janitor, pid)
  sync(janitor)
  handler_count(["collector_test", "stopped"]) |> should.equal(0)
}

// Sources attach all or nothing: when one is refused, the start fails and
// none of them stays attached.
pub fn a_refused_source_fails_the_start_and_attaches_none_test() {
  let event = count_event("refused")
  let name = process.new_name("collector-refused")
  // Another live process holds the id of the collector's second source.
  let assert Ok(incumbent) =
    sinal.attach(
      sinal.subscription(event, fn(_, _) { Nil })
      |> sinal.with_id("sinal/collector:" <> name_to_string(name) <> ":1"),
    )
  let recent: Collector(Int) = collector.new(name)
  let spec =
    collector.supervised(recent, [
      collector.source(event, fn(n, _) { n }),
      collector.source(event, fn(n, _) { n + 1 }),
    ])
  spec.start() |> should.be_error
  handler_count(["collector_test", "refused"]) |> should.equal(1)
  let assert Ok(Nil) = sinal.detach(incumbent)
}

pub fn a_collector_that_is_not_running_discards_and_reads_empty_test() {
  let recent: Collector(Int) =
    collector.new(process.new_name("collector-absent"))
  collector.record(recent, 1)
  collector.entries(recent) |> should.equal([])
  collector.recorded(recent) |> should.equal(0)
}

pub fn a_capacity_below_one_fails_the_start_test() {
  let recent: Collector(Int) =
    collector.new(process.new_name("collector-zero"))
    |> collector.with_capacity(0)
  let spec = collector.supervised(recent, [])
  spec.start() |> should.be_error
}

pub fn source_with_records_selected_occurrences_test() {
  let event = count_event("selected")
  let #(recent, _) =
    start("collector-selected", 4, [
      collector.source_with(fn(record) {
        sinal.subscription(event, fn(n, _) {
          case n > 1 {
            True -> record(n)
            False -> Nil
          }
        })
      }),
    ])
  emit_range(event, 1, 3)
  collector.entries(recent) |> should.equal([2, 3])
  list.length(collector.entries(recent)) |> should.equal(2)
}

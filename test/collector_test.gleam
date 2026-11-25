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
  collector.detach(recent)
}

pub fn keeps_only_the_newest_capacity_entries_test() {
  let event = count_event("bounded")
  let #(recent, _) =
    start("collector-bounded", 4, [collector.source(event, fn(n, _) { n })])
  emit_range(event, 1, 1000)
  collector.entries(recent) |> should.equal([997, 998, 999, 1000])
  collector.recorded(recent) |> should.equal(1000)
  collector.detach(recent)
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
  // One handler serves both incarnations: the entry is recorded once.
  collector.entries(recent) |> should.equal([2])
  collector.recorded(recent) |> should.equal(1)
  collector.detach(recent)
}

pub fn detach_stops_collecting_test() {
  let event = count_event("detach")
  let #(recent, _) =
    start("collector-detach", 4, [collector.source(event, fn(n, _) { n })])
  sinal.emit(event, 1, "w")
  collector.detach(recent)
  sinal.emit(event, 2, "w")
  collector.entries(recent) |> should.equal([1])
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
  collector.detach(recent)
}

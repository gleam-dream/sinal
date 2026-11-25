//// A bounded collector that keeps the most recent observations in memory,
//// and a group of handlers attached all or nothing.

import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/otp/static_supervisor
import sinal
import sinal/collector.{type Collector}
import usage/records.{type HttpMeasurements, type HttpMetadata}

// snips-start: collect-recent
/// Supervises a collector that keeps the 256 most recent request lines.
pub fn collect_requests(
  name: process.Name(collector.Message(String)),
  event: sinal.Event(HttpMeasurements, HttpMetadata),
) -> Collector(String) {
  let recent = collector.new(name) |> collector.with_capacity(256)
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(
      collector.supervised(recent, [
        collector.source(event, fn(measurements, metadata) {
          metadata.route <> " " <> int.to_string(measurements.duration_ms)
        }),
      ]),
    )
    |> static_supervisor.start
  recent
}

// snips-end: collect-recent

/// Collect two requests, read them back, and attach a group of handlers.
pub fn run() -> Nil {
  let event = records.http_request_event()
  let recent = collect_requests(process.new_name("usage_collector"), event)
  let request = fn(route: String, duration_ms: Int) {
    sinal.emit(
      event,
      records.HttpMeasurements(duration_ms:, bytes_sent: 1),
      records.HttpMetadata(method: records.Get, route:, status: 200),
    )
  }
  request("/users", 4)
  request("/orders", 9)
  assert collector.entries(recent) == ["/users 4", "/orders 9"]
  assert collector.recorded(recent) == 2
  collector.detach(recent)

  // Long-lived handlers for several events attach together or not at all.
  let assert Ok(attachments) =
    sinal.attach_all([
      sinal.subscription(event, fn(_, _) { Nil }),
      sinal.subscription(event, fn(_, _) { Nil }),
    ])
  assert list.map(attachments, sinal.detach) == [Ok(Nil), Ok(Nil)]
}

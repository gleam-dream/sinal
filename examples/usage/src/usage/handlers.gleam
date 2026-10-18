//// A fallible handler with a typed failure observer, a label and a stable id.

import sinal
import usage/records.{type HttpMeasurements, type HttpMetadata}

pub fn attach_metrics(
  event: sinal.Event(HttpMeasurements, HttpMetadata),
) -> sinal.Attachment {
  let subscription =
    sinal.handler(
      [event],
      fn(_event, measurements: HttpMeasurements, _metadata: HttpMetadata) {
        case measurements.duration_ms >= 0 {
          True -> Ok(Nil)
          False -> Error("negative duration")
        }
      },
      fn(_event, failure) {
        // A malformed native map skips this one event and keeps the
        // handler; after an `Error` from the handler, telemetry removes it.
        let _ = sinal.describe_handler_failure(failure, fn(e) { e })
        Nil
      },
    )
    |> sinal.with_id("http-metrics")
  let assert Ok(attachment) = sinal.attach(subscription)
  attachment
}

/// Attach under a stable id, check that a second attach under the same id is
/// refused, and detach.
pub fn run() -> Nil {
  let event = records.http_request_event()
  let attachment = attach_metrics(event)
  sinal.emit(
    event,
    records.HttpMeasurements(duration_ms: 1, bytes_sent: 1),
    records.HttpMetadata(method: records.Get, route: "/", status: 200),
  )
  assert sinal.attach(
      sinal.subscription(event, fn(_, _) { Nil })
      |> sinal.with_id("http-metrics"),
    )
    == Error(sinal.AlreadyExists("http-metrics"))
  let assert Ok(Nil) = sinal.detach(attachment)
  Nil
}

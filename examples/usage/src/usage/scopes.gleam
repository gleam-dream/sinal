//// Subscriptions that exist only while some work runs.

import gleam/erlang/process
import sinal
import usage/records.{type HttpMeasurements, type HttpMetadata}

pub fn count_requests(
  event: sinal.Event(HttpMeasurements, HttpMetadata),
  work: fn() -> a,
) -> Result(sinal.SubscriptionCompletion(a), sinal.SubscriptionScopeError) {
  let seen = process.new_subject()
  let observer = sinal.subscription(event, fn(_, _) { process.send(seen, Nil) })
  // Attached before `work` runs and detached when it returns or raises.
  sinal.with_subscriptions(sinal.subscriptions([observer]), work)
}

/// Run work inside a scope and check its result and clean cleanup.
pub fn run() -> Nil {
  let event = records.http_request_event()
  let assert Ok(completion) =
    count_requests(event, fn() {
      sinal.emit(
        event,
        records.HttpMeasurements(duration_ms: 1, bytes_sent: 1),
        records.HttpMetadata(method: records.Get, route: "/", status: 200),
      )
      42
    })
  assert completion.work_result == 42
  assert completion.cleanup_failures == []
}

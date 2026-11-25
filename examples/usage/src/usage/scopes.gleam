//// Subscriptions that exist only while some work runs.

import gleam/erlang/process
import gleam/otp/static_supervisor
import sinal
import sinal/janitor
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

/// The same scope, bound to the calling process through a janitor the
/// application supervises. When an exit signal terminates the process
/// before the scope's own cleanup runs, the janitor detaches the handler.
pub fn count_requests_owned(
  cleaner: janitor.Janitor,
  event: sinal.Event(HttpMeasurements, HttpMetadata),
  work: fn() -> a,
) -> Result(sinal.SubscriptionCompletion(a), sinal.SubscriptionScopeError) {
  let seen = process.new_subject()
  let observer = sinal.subscription(event, fn(_, _) { process.send(seen, Nil) })
  sinal.subscriptions([observer])
  |> sinal.with_janitor(cleaner)
  |> sinal.with_subscriptions(work)
}

/// Supervises the janitor, once, at application start.
pub fn start_janitor(name: process.Name(janitor.Message)) -> janitor.Janitor {
  let cleaner = janitor.new(name)
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(janitor.supervised(cleaner))
    |> static_supervisor.start
  cleaner
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

  let cleaner = start_janitor(process.new_name("usage_janitor"))
  let assert Ok(owned) = count_requests_owned(cleaner, event, fn() { 7 })
  assert owned.work_result == 7
  assert owned.cleanup_failures == []
}

# Migrating from Sinal 0.1 to 0.2

Sinal 0.2.0 is a breaking release. Change the dependency to `sinal >= 0.2.0 and < 0.3.0` in `gleam.toml`, then work through the sections below in order. The first one affects most applications.

| Change                                                                                      | Who must act                                                               |
| ------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| [Handlers are bound to the attaching process](#handlers-are-bound-to-the-attaching-process) | Every application that attaches a handler outside a long-lived process     |
| [A stale attachment detaches nothing](#a-stale-attachment-detaches-nothing)                 | Code that keeps an old attachment, or detaches a handler it did not attach |
| [Diagnostics log once and are counted](#diagnostics-log-once-and-are-counted)               | Code that matches Sinal's warning text or monitors the warning rate        |
| [Span events follow forwarder routes](#span-events-follow-forwarder-routes)                 | Applications that route a prefix that covers a span                        |
| [The native handler configuration changed](#the-native-handler-configuration-changed)       | Native Erlang or Elixir code that reads Sinal handler configurations       |

New in 0.2.0 and not breaking: `sinal.attach_all`, `sinal.diagnostics`, `sinal/diagnostic`, and `sinal/collector`.

## Handlers are bound to the attaching process

**What changed.** Every handler from `sinal.attach`, `sinal.observe`, `sinal.observe_labelled`, and `sinal.with_subscriptions` now belongs to the process that attached it, its owner. Sinal detaches the handler when the owner exits for any reason, including a normal return. In 0.1 the handler stayed attached until `sinal.detach` or until the node stopped.

**Why.** A handler whose owner was killed stayed in the node-wide telemetry registry with everything its closure captured, so each restart of a process that attached handlers grew the registry.

**What to do.** Attach a handler that must live as long as the application from a long-lived supervised process, never from a function that runs once and returns. Typical 0.1 code attached in `main` or in a setup function that a short-lived process ran:

```gleam
// 0.1: the handler outlived the process that ran setup.
pub fn setup() -> Nil {
  let _attachment = sinal.observe(finished, record_request)
  Nil
}
```

In 0.2 that handler is detached as soon as the process that called `setup` exits. Attach from the process that stays alive, for example in an actor's initialiser. A supervisor that restarts the actor then restarts the handler, and the old handler goes with the old actor:

```gleam
actor.new_with_initialiser(1000, fn(subject) {
  // The actor's process owns the handler.
  let _attachment = sinal.observe(finished, record_request)
  actor.initialised(Nil) |> actor.returning(subject) |> Ok
})
```

Call `setup` from `main` only when `main` itself keeps running, for example by sleeping forever after it starts the supervisor. A test that attaches in one process and emits in another keeps working while the attaching process is alive.

To attach several handlers from one long-lived process, use `sinal.attach_all`. It installs the list in order and returns `Result(List(Attachment), SubscriptionScopeError)`. When an attach is refused, it detaches the earlier handlers and returns `SubscriptionAttachFailed`. If one of those rollback detaches fails, that handler can stay installed until its owner exits, and `rollback_failures` names it. Check `rollback_failures` when the group must leave nothing behind.

**Other effects.**

- `sinal.attach` now waits for Sinal's own process, started by the `sinal` OTP application, to answer, with no deadline. It panics, leaving no handler, only when that process exits before answering. It starts the `sinal` and `telemetry` applications when they are not running.
- A `with_id` id held by an owner that has exited passes to the new owner. An id held by a live owner is still refused with `AlreadyExists`. A process that a supervisor restarts can therefore attach under the same stable id again.
- Removal follows the owner's exit without being synchronous with it. An emitter can still reach the handler in between, and a callback already running in another process finishes.
- A handler that another library attached with native `:telemetry.attach` has no Sinal owner and is left alone.

## A stale attachment detaches nothing

**What changed.** An `Attachment` now names one registration. `sinal.detach` returns `Error(Nil)` when that registration is gone: detached before, removed by telemetry after a failure, or released because its owner exited. It never detaches a later registration that reuses the same id. In 0.1 detaching by id also removed a newer handler with that id.

**Why.** A copied old attachment must not remove a replacement handler.

**What to do.** Keep the attachment that the latest `attach` returned. Treat `Error(Nil)` from `detach` as "already gone", not as a failure of the detach. Any process can detach a handler, not only its owner.

```gleam
// Before: a second detach of an id that a newer handler now holds removed the newer handler.
let _ = sinal.detach(old_attachment)

// After: that call returns Error(Nil) and leaves the newer handler attached.
case sinal.detach(latest_attachment) {
  Ok(Nil) -> Nil
  // Already gone: its owner exited or another caller detached it.
  Error(Nil) -> Nil
}
```

## Diagnostics log once and are counted

**What changed.** Two Sinal conditions are now diagnostics: an emitted `fields.enum` value that its list does not name (`UnlistedValue`), and an `observe` or `subscription` invocation skipped because a native map did not decode (`SkippedInvocation`). Each logs one warning per condition and event name, on the first occurrence, and later occurrences are only counted. In 0.1 every occurrence logged a warning. The warning text now ends with `. Later occurrences are counted; sinal.diagnostics() reads the total`.

**Why.** A faulty definition repeats the condition on every event, which floods the log on a hot path.

**What to do.**

- Update any log matcher on the old warning text. The logger domain is `[sinal]`.
- To monitor a recurring condition, poll `sinal.diagnostics()`. It returns `List(diagnostic.Diagnostic)`, each with `kind`, `event`, and the exact `total` since the node started. Reading does not reset the counts. For a rate, subtract the previous reading.

```gleam
import gleam/list
import sinal
import sinal/diagnostic

pub fn skipped_total() -> Int {
  sinal.diagnostics()
  |> list.filter(fn(entry) { entry.kind == diagnostic.SkippedInvocation })
  |> list.fold(0, fn(sum, entry) { sum + entry.total })
}
```

The counts last for the life of the node and are kept per condition and event name, not per handler.

## Span events follow forwarder routes

**What changed.** `span.run` measures the span in the calling process, then dispatches its start, stop, and exception events as `sinal.emit` does. When a prefix route matches the name of one of a span's events (the span name followed by `start`, `stop`, or `exception`), that event's handlers run in the forwarder process, not in the producer. In 0.1 spans ignored routes and always ran their handlers in the producer.

**Why.** A routed prefix is meant to keep callback work off the producer, and spans broke that rule.

**What to do.** Nothing, for a span whose start, stop, and exception event names no route matches. A route such as `["db", "query", "stop"]` does not match the span name `["db", "query"]` but does match its stop event. For a span with a routed event name:

- A handler no longer sees the producer's process-dictionary context. Carry what it needs in the span's metadata.
- A full or unavailable forwarder drops the span's events as it drops any routed event, so a handler can see a start without a stop.
- To keep a span's handlers in the producer, remove the routes that match the span's start, stop, and exception event names.

## The native handler configuration changed

**What changed.** The configuration of every Sinal handler in native telemetry is now `{sinal_owner, Owner, Token, Callback}`, where 0.1 stored the callback alone. It appears in `:telemetry.list_handlers/1` and in the `handler_config` of a `[telemetry, handler, failure]` event.

**What to do.** Only native Erlang or Elixir code that inspects Sinal handlers is affected. Match the new tuple, or ignore the configuration. Do not detach a Sinal handler through `:telemetry.detach`; use `sinal.detach`, which keeps Sinal's record of the registration exact.

## Checklist

1. Set the dependency to `sinal >= 0.2.0 and < 0.3.0`.
2. Find each call to `attach`, `observe`, `observe_labelled`, and `with_subscriptions` that a short-lived process runs, and move it into a long-lived supervised process.
3. Find each retained `Attachment` that outlives a restart and replace it with the one from the latest `attach`.
4. Replace log matchers on Sinal warnings with `sinal.diagnostics()` polling.
5. Check each route prefix against the start, stop, and exception event names of each span.

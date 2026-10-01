# sinal

A strongly-typed take on Erlang `:telemetry`, built for Gleam's generics instead of dynamic maps and atoms.

`sinal` wraps native BEAM `:telemetry` 1.4.2 directly. It replaces untyped string/atom map lookups with type-safe generic codecs (`Fields(t)`), structured event descriptors (`Event(m, d)`), and typed span execution. Typed encoding and decoding execute directly at the callback boundary; the included microbenchmarks establish an empirical performance baseline.

---

## Target and Support Matrix

| Target            | Status                        | Notes                                                                                                                  |
| :---------------- | :---------------------------- | :--------------------------------------------------------------------------------------------------------------------- |
| **Erlang / BEAM** | **Initial release candidate** | Full initial facade implemented. CI uses Gleam 1.18.1 and Erlang/OTP 28 with `:telemetry` 1.4.2.                       |
| **JavaScript**    | **Unsupported**               | Explicitly unsupported. `:telemetry` relies on BEAM ETS tables, `persistent_term`, process mailboxes, and atom tables. |

---

## Architecture and Core Design

1. **Direct Native Binding**: Measurements and metadata are decoded directly from native Erlang maps into typed Gleam records via explicit field codecs at the callback boundary.
2. **Atom Safety**: Event prefixes and field names use Erlang atoms. Atoms must be trusted constants or pre-validated identifiers; never dynamically construct atoms from untrusted user strings.
3. **Same-Process Synchronous Dispatch**: Telemetry handlers execute synchronously inside the emitting process.
4. **Honest Failure Isolation**: Handler errors and malformed maps notify a local typed observer and emit the standard native `[telemetry, handler, failure]` event before removing the failing handler, without crashing the emitter.

---

## Getting Started

The manifest targets Gleam 1.18 or newer and Erlang/BEAM only. `telemetry` 1.4.2 is a direct dependency; applications do not need to declare it separately. The dependency declaration below is for the planned initial release:

```toml
[dependencies]
sinal = ">= 0.1.0 and < 1.0.0"
```

---

## Usage Examples

Register long-lived handlers during application startup, before events are emitted, and retain each `Attachment` for shutdown cleanup. A public `HandlerId` must be unique among currently attached native telemetry handlers; an occupied ID returns `AlreadyExists`. `sinal` needs no global configuration step; its only node-wide setting is an optional forwarder route (see section 7). Define event names and field keys as trusted atoms in application code, and attach the resulting descriptors where their lifecycle is owned. Temporary observers can use `with_subscriptions`; its acquisition is sequential and visible to concurrent emitters.

The examples are exercised against BEAM `:telemetry` in `test/sinal_test.gleam` and `test/readme_example_test.gleam`.

Common imports used across examples:

- `import sinal`
- `import sinal/fields`
- `import sinal/span`
- `import sinal/forwarder`
- `import gleam/erlang/atom`
- `import gleam/erlang/process`
- `import gleam/dynamic`
- `import gleam/dynamic/decode`
- `import gleam/otp/static_supervisor`

For ordinary events, use `sinal.event` and the primitive `fields.string`,
`fields.int`, and `fields.bool` constructors. Keys and event names must be
trusted, application-defined atoms. Use `fields.field` for custom native
fields with explicit encode and decode functions.

An infallible observer needs only the decoded measurements and metadata:

```gleam
pub fn observe_request_example() {
  let assert Ok(ev) =
    sinal.event(
      [atom.create("request"), atom.create("finished")],
      fields.int(atom.create("duration_ms")),
      fields.string(atom.create("route")),
    )
  let assert Ok(id) = sinal.handler_id("request-finished-observer")
  let assert Ok(attachment) =
    sinal.observe(id, ev, fn(_duration_ms, _route) {
      // Handle the event synchronously in the emitting process.
      Nil
    })
  let assert Ok(Nil) = sinal.emit(ev, 42, "/users")
  let assert Ok(Nil) = sinal.detach(attachment)
}
```

`observe` uses the same native attachment path as `attach`. Malformed native
maps and observer exceptions remove the registration and emit the standard
`[telemetry, handler, failure]` event; `observe` does not expose a typed failure
callback. Use `attach` when you need a fallible handler, the selected event
descriptor, or a typed failure callback. Keep the returned attachment to detach
an observer explicitly.

### 1. Defining Fields and Events

Events are parameterized by measurement and metadata types: `Event(measurements, metadata)`.

```gleam
pub type HttpMeasurements {
  HttpMeasurements(duration_ms: Int, bytes_sent: Int)
}

pub type HttpMetadata {
  HttpMetadata(method: String, route: String, status: Int)
}

pub fn http_request_event() -> Result(
  sinal.Event(HttpMeasurements, HttpMetadata),
  sinal.EventError,
) {
  let dur_field =
    fields.field(
      atom.create("duration_ms"),
      fn(i: Int) { Ok(dynamic.int(i)) },
      fn(dyn) {
        case decode.run(dyn, decode.int) {
          Ok(i) -> Ok(i)
          Error(_) -> Error(fields.FieldDecodeError("expected int duration_ms"))
        }
      },
    )

  let bytes_field =
    fields.field(
      atom.create("bytes_sent"),
      fn(b: Int) { Ok(dynamic.int(b)) },
      fn(dyn) {
        case decode.run(dyn, decode.int) {
          Ok(i) -> Ok(i)
          Error(_) -> Error(fields.FieldDecodeError("expected int bytes_sent"))
        }
      },
    )

  let assert Ok(meas_pair) = fields.pair(dur_field, bytes_field)
  let meas_fields =
    fields.imap(
      meas_pair,
      fn(p) { HttpMeasurements(p.0, p.1) },
      fn(m: HttpMeasurements) { #(m.duration_ms, m.bytes_sent) },
    )

  let method_field = fields.string(atom.create("method"))

  let route_field =
    fields.field(
      atom.create("route"),
      fn(r: String) { Ok(dynamic.string(r)) },
      fn(dyn) {
        case decode.run(dyn, decode.string) {
          Ok(s) -> Ok(s)
          Error(_) -> Error(fields.FieldDecodeError("expected string route"))
        }
      },
    )

  let status_field =
    fields.field(
      atom.create("status"),
      fn(s: Int) { Ok(dynamic.int(s)) },
      fn(dyn) {
        case decode.run(dyn, decode.int) {
          Ok(s) -> Ok(s)
          Error(_) -> Error(fields.FieldDecodeError("expected int status"))
        }
      },
    )

  let assert Ok(method_route) = fields.pair(method_field, route_field)
  let assert Ok(meta_triple) = fields.pair(method_route, status_field)
  let meta_fields =
    fields.imap(
      meta_triple,
      fn(p) {
        let #(#(method, route), status) = p
        HttpMetadata(method: method, route: route, status: status)
      },
      fn(m: HttpMetadata) { #(#(m.method, m.route), m.status) },
    )

  sinal.event(
    [atom.create("http"), atom.create("server"), atom.create("request")],
    meas_fields,
    meta_fields,
  )
}
```

### 2. Emitting Events

```gleam
pub fn log_request(ev: sinal.Event(HttpMeasurements, HttpMetadata)) {
  let meas = HttpMeasurements(duration_ms: 42, bytes_sent: 2048)
  let meta = HttpMetadata(method: "GET", route: "/api/users", status: 200)

  case sinal.emit(ev, meas, meta) {
    Ok(Nil) -> Nil
    Error(sinal.EncodingFailed(fields.FieldEncodeError(msg))) -> panic as msg
  }
}
```

### 3. Attaching and Detaching Handlers

```gleam
pub fn setup_metrics(ev: sinal.Event(HttpMeasurements, HttpMetadata)) {
  let assert Ok(hid) = sinal.handler_id("prometheus-http-metrics")

  let handler = fn(
    _event,
    _measurements: HttpMeasurements,
    _metadata: HttpMetadata,
  ) {
    // Record metrics synchronously
    Ok(Nil)
  }

  let on_failure = fn(_event, _failure) {
    // Called if measurements/metadata cannot be decoded or handler returned Error
    Nil
  }

  let assert Ok(attachment) = sinal.attach(hid, ev, handler, on_failure)

  // Later, cleanly detach handler:
  let assert Ok(Nil) = sinal.detach(attachment)
  Nil
}
```

### 4. Scoped Subscriptions

Bind an event and observer as a pure `Subscription`, then run with any mix of
measurement and metadata types. Acquisition is sequential, so concurrent
emitters can observe a partial set while it is being installed. On acquisition
failure, work is skipped and earlier registrations are detached. Cleanup runs
on normal return or catchable BEAM exception (error, exit, throw), preserving
the original exception. Uncatchable termination such as `kill` bypasses cleanup.

```gleam
pub fn scoped_metrics_example(
  event: sinal.Event(HttpMeasurements, HttpMetadata),
) -> Result(sinal.SubscriptionCompletion(Int), sinal.SubscriptionScopeError) {
  let observer = sinal.subscription(event, fn(_measurements, _metadata) { Nil })

  sinal.with_subscriptions(sinal.subscriptions([observer]), fn() {
    // Work runs with attachments active.
    // Detach runs on normal return or catchable error, exit, or throw.
    // Original error/exit/throw is re-raised with exact origin stacktrace.
    42
  })
}
```

`handler_subscription(id, event, handler, on_failure)` retains a typed handler
error and lets the application choose a handler ID. `with_subscriptions` reports
the zero-based index of an acquisition failure and any rollback failures; a
successful run carries its work result and indexed cleanup failures. A raised
acquisition exception also rolls back prior registrations before it is
re-raised. Use `with_exception_cleanup_reporter(plan, reporter)` if cleanup
failures during exception unwinding need separate reporting. `attach_many` and
`with_attachments` remain the native same-shaped
grouping path when one registration must cover multiple event names.

### 5. Native Telemetry Spans (`sinal/span`)

Execute code wrapped in standard `:telemetry` spans, emitting start and stop (or exception) events:

```gleam
pub type QueryMeta {
  QueryMeta(sql: String)
}

pub fn query_meta_fields() -> fields.Fields(QueryMeta) {
  let query_key = atom.create("sql")
  fields.field(
    query_key,
    fn(q: QueryMeta) { Ok(dynamic.string(q.sql)) },
    fn(dyn) {
      case decode.run(dyn, decode.string) {
        Ok(s) -> Ok(QueryMeta(s))
        Error(_) -> Error(fields.FieldDecodeError("expected string sql"))
      }
    },
  )
}

pub fn run_database_query(query_str: String) -> String {
  // Simulated database execution
  "result for: " <> query_str
}

pub fn execute_traced_query(query_str: String) -> String {
  let assert Ok(prefix) =
    span.event_prefix([atom.create("db"), atom.create("query")])
  let assert Ok(sp) =
    span.define_span(
      prefix,
      query_meta_fields(),
      fields.empty(),
      query_meta_fields(),
    )

  span.run_span(sp, QueryMeta(sql: query_str), fn() {
    let result = run_database_query(query_str)
    span.Completion(
      result: result,
      measurements: Nil,
      metadata: QueryMeta(sql: query_str),
    )
  })
}
```

`run_span_result` returns `SpanCompleted(result)`, `StartEncodingFailed(error)`,
or `CompletionEncodingFailed(result, error)`. A start encoding failure runs no
work and emits no event. A completion encoding failure retains the completed
business result and delegates to native telemetry to emit an exception event
whose structured reason identifies the instrumentation failure; the result is
kept private from that event. It emits no stop event. Catchable work exceptions
follow native telemetry's exception path and retain their original class,
reason, and stacktrace. `run_span` is the distinct raising policy for encoding
failures. Use `duration_in(duration, Millisecond)`,
`system_time_in(time, Second)`, or `monotonic_time_in(time, Native)` to read
timing values in an explicit `TimeUnit`. All native timing fields must decode
as integers before their opaque wrappers are constructed.

### 6. Forwarded Delivery (`sinal/forwarder`)

Every handler attached with `sinal.attach`/`sinal.observe` runs synchronously
in the emitting process, so a slow or blocked handler stalls the producer.
`sinal/forwarder` is an additive, opt-in hop: it hands an already-encoded
event to a dedicated forwarder process before any handler runs, so a stalled
handler blocks the forwarder instead of the producer. `sinal.emit` and
`sinal.attach`/`sinal.observe` are unchanged for any caller that does not use
it.

```gleam
pub fn build_supervisor(forwarder_name: process.Name(forwarder.Message)) {
  let assert Ok(fwd) = forwarder.new(forwarder_name, 1024)
  let assert Ok(_started) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(forwarder.supervised(fwd))
    |> static_supervisor.start
  fwd
}

pub fn emit_via_forwarder(
  fwd: forwarder.Forwarder,
  ev,
  measurements,
  metadata,
) {
  case forwarder.emit(fwd, ev, measurements, metadata) {
    Ok(Nil) -> Nil
    Error(forwarder.ForwardEncodingFailed(_)) -> panic as "bad event shape"
    Error(forwarder.CapacityExceeded) -> Nil
    Error(forwarder.ForwarderUnavailable) -> Nil
  }
}
```

`forwarder.new(name, capacity)` allocates the forwarder's shared counters
without starting a process; `capacity` must be positive. Pass a
`process.Name` created once at application start, the same way any named
`gleam_erlang` process is named — never inside a loop. `forwarder.supervised`
turns the result into a `supervision.ChildSpecification(Nil)` for an OTP
supervisor to own and restart.

`forwarder.emit` encodes with the same `Fields` codecs as `sinal.emit`, then
hands the event to the forwarder process, returning as soon as that hand-off
completes without waiting for any attached handler:

- `ForwardEncodingFailed(error)` — the same encoding failure `sinal.emit`
  would report. It never reaches the capacity counters, so it never consumes
  a slot.
- `CapacityExceeded` — the forwarder already has `capacity` messages in
  flight; this send is dropped and counted as `rejected` in the forwarder's
  own `[sinal, forwarder, dropped]` event (`forwarder.dropped_event()`,
  carrying `Dropped(rejected:, lost:, unavailable:)`), reported once per
  `ReportDrops` drain cycle rather than once per drop.
- `ForwarderUnavailable` — no incarnation has published a forwarding target
  (not started, still initialising, or between incarnations). The send is
  dropped and counted as `unavailable`. A later drop drain or supervised
  restart can report it. A replacement starts with fresh admission capacity;
  it never inherits the previous actor's queued events.

Handlers attach exactly as before — same `sinal.attach`/`sinal.observe`, same
native failure isolation for a handler that raises — except their `self()`
is the forwarder process, not the original caller, and process-dictionary
context from the caller is not carried across the hop. Unlike a raise, a
handler's own _exit_ (from a link, or an untrappable `kill`) is not isolated
by native telemetry and can take the forwarder process down. See "Operational
Limits and Semantics" below for the forwarder's delivery, ordering, and
restart guarantees. Constructing more than one `Forwarder` for the same
`process.Name` gives each its own, unshared counters — use one `Forwarder`
value per name.

### 7. Routing a Library's Events (`sinal/forwarder`)

A library that emits observations cannot know whether its application wants
them synchronous or forwarded, and should not own a forwarder's name and
capacity. It calls `forwarder.emit_routed`; the application decides with
`forwarder.route(prefix, forwarder)`, once, at startup.

```gleam
pub fn route_library_events(fwd: forwarder.Forwarder) -> Nil {
  // Application start, after the forwarder is supervised.
  forwarder.route([atom.create("my_library")], fwd)
}

pub fn library_observe(ev, measurements, metadata) -> Nil {
  // Library code: forwarded if the application routed this name,
  // synchronous otherwise. Drops are the forwarder's to report.
  let _ = forwarder.emit_routed(ev, measurements, metadata)
  Nil
}
```

- **No route: synchronous.** An `emit_routed` event whose name has no routed
  prefix is exactly `sinal.emit`: handlers run in the caller and finish before
  it returns. An application that routes nothing changes nothing.
- **Longest prefix wins.** A route covers every event whose name starts with
  its prefix; `[]` covers every routed event. Routing a prefix again replaces
  its forwarder; `forwarder.unroute(prefix)` removes it.
- **A routed event never blocks and never falls back inline.** It behaves
  exactly as `forwarder.emit` to that forwarder: over capacity it is dropped,
  returns `CapacityExceeded`, and is counted as `rejected` in the forwarder's
  `[sinal, forwarder, dropped]` report; with the forwarder not running it is
  dropped, returns `ForwarderUnavailable`, and is counted as `unavailable` in
  the report its next incarnation makes when it starts. A library can
  therefore ignore the result without hiding a loss. There is no
  backpressure: the emitter never waits for handler execution.
- **Handler failures stay off the emitter.** A raising handler is detached by
  native telemetry on either path. Behind a route, a handler exit that stops
  the forwarder loses its in-flight events, which the restarted forwarder
  reports as `Dropped(lost:)`.
- **The library accepts a different `self()`.** A library that emits through
  `emit_routed` must not rely on its caller's process dictionary in handlers,
  and cannot route a native span.

`sinal.emit` and `forwarder.emit` never consult routes, and a forwarder
emits its own `dropped_event` directly with `sinal.emit`, so a route (even
`[]`) cannot loop, and reporting a drop never causes another drop.

---

## Operational Limits and Semantics

- **Span event names**: `span.events(sp)` exposes typed `start`, `stop`, and `exception` descriptors for a span prefix. Attach observers before calling `run_span` or `run_span_result` when those events must be seen. Native telemetry owns the lifecycle and timing fields.
- **Span result retention**: `run_span_result` preserves a completed work result when stop instrumentation encoding fails. It cannot recover a result from work that raises; native telemetry emits an exception event and re-raises the original exception.
- **Synchronous Execution**: Handlers execute synchronously in the caller process. Slow handlers directly block the emitter.
- **Unspecified Handler Order**: When multiple handlers are attached to an event, the order in which `:telemetry` calls them is explicitly unspecified.
- **Non-Quiescence on Detach**: Detaching a handler prevents it from being selected for subsequent event emissions. However, if a callback is already executing in flight in another process, detaching does not wait for or abort that in-flight execution.
- **Uncatchable VM Exits**: Abrupt process exits or untrappable signals (`kill`) bypass cleanup hooks.
- **Storage Migration**: Handlers initially live in ETS tables. Calling `:telemetry.persist/0` compiles them into `persistent_term` for read-optimized lookup without interrupting event delivery.
- **No Network Export or Unbounded Buffering**: `sinal` is an in-process telemetry delivery facade. Network export (OTLP, StatsD, Prometheus) and unbounded batch buffering belong in dedicated adapter processes. `sinal/forwarder` (above) is the one in-core exception, and it is deliberately narrow: a bounded, best-effort, in-process hop, not a queue, not export, and not a substitute for a real buffering adapter.
- **Forwarder delivery is best-effort**: `forwarder.emit` never blocks and never retries. A send that would exceed capacity, or that targets a forwarder not currently running, is dropped and reported rather than queued.
- **Forwarder ordering is per-producer, not global**: native BEAM message ordering guarantees a single producer's forwarded events are dispatched in the order it sent them. Interleaving across producers is unspecified, as it already is for native telemetry handler order.
- **The forwarder is the handler's `self()`**: a handler attached to a forwarded event runs inside the forwarder process, not the original caller. Process-dictionary context from the producer is not carried across the hop, and a native telemetry span cannot be forwarded (its start and stop must share one process to measure duration).
- **Routed ordering holds per route**: a producer's `emit_routed` events that resolve to the same forwarder, or that are all unrouted, keep its send order. Events split across routes, or across a route change, have no relative order; after an `unroute`, a later synchronous event can run before an earlier forwarded one.
- **Routes are node-global setup values**: they live in `persistent_term`, so `emit_routed` reads them without a lock (with no routes, it costs one lookup over `sinal.emit`; see the benchmark), while `route` and `unroute` are expensive and belong at application start and shutdown. Unroute before stopping a routed forwarder, or its events are dropped as unavailable (counted, but reported only if that forwarder starts again).
- **Forwarder shutdown does not drain**: messages still in flight when the forwarder process stops are lost, not delivered. A supervised restart schedules a diagnostic `Dropped(lost:)` snapshot from the replacement process; it is not exact delivery accounting.
- **Drop reporting is best effort**: `rejected` counts capacity refusals and `unavailable` counts sends made without a published target. These diagnostic counters survive restarts. `lost` snapshots outstanding work when a replacement starts; races with producers and handler completion can over- or under-count it. Reports can themselves be lost when their process stops. Observation success is never a delivery receipt.
- **Capacity belongs to an incarnation**: a one-row named ETS table publishes a direct event subject together with fresh admission counters after initialisation. The table is owned by the actor and disappears on its death. A delayed producer retains the old subject and counters and cannot send into a replacement actor. Before publication, sends return `ForwarderUnavailable`. Admission counts pending events plus the executing handler. An incarnation also has one coalesced drop-notice flag and an optional startup report; delayed drop notices keep the old direct destination. An existing ETS table with the forwarder name makes startup fail with `InitFailed`.
- **Concurrent emitters may see a spurious, safe rejection near the capacity boundary**: admission is a single atomic increment-then-check, so it never over-admits, but under concurrent load at the boundary it can reject a send that would have fit under a different ordering. It never admits past capacity.

---

## Development, Tests & Benchmarks

To enter the dev shell and run test suites:

```sh
# Enter reproducible dev environment
nix develop

# Run unit tests and bounded stress harness
gleam test

# Run microbenchmarks (reproducible latency and throughput baseline)
gleam run -m benchmark

# Run standalone bounded stress test
gleam run -m stress_test

# Validate documentation generation
gleam docs build

# Validate Hex package generation (dry run)
gleam export hex-tarball
```

The synchronized forwarder startup/restart regression command is `python3 dev/check_forwarder.py` inside the development shell. It instruments disposable source copies only; production code contains no test hooks.

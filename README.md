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

Register long-lived handlers during application startup, before events are emitted, and retain each `Attachment` for shutdown cleanup. A public `HandlerId` must be unique among currently attached native telemetry handlers; an occupied ID returns `AlreadyExists`. `sinal` has no global configuration step. Define event names and field keys as trusted atoms in application code, and attach the resulting descriptors where their lifecycle is owned. Temporary observers can use `with_subscriptions`; its acquisition is sequential and visible to concurrent emitters.

The examples are exercised against BEAM `:telemetry` in `test/sinal_test.gleam` and `test/readme_example_test.gleam`.

Common imports used across examples:

- `import sinal`
- `import sinal/fields`
- `import sinal/span`
- `import gleam/erlang/atom`
- `import gleam/dynamic`
- `import gleam/dynamic/decode`

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

---

## Operational Limits and Semantics

- **Span event names**: `span.events(sp)` exposes typed `start`, `stop`, and `exception` descriptors for a span prefix. Attach observers before calling `run_span` or `run_span_result` when those events must be seen. Native telemetry owns the lifecycle and timing fields.
- **Span result retention**: `run_span_result` preserves a completed work result when stop instrumentation encoding fails. It cannot recover a result from work that raises; native telemetry emits an exception event and re-raises the original exception.
- **Synchronous Execution**: Handlers execute synchronously in the caller process. Slow handlers directly block the emitter.
- **Unspecified Handler Order**: When multiple handlers are attached to an event, the order in which `:telemetry` calls them is explicitly unspecified.
- **Non-Quiescence on Detach**: Detaching a handler prevents it from being selected for subsequent event emissions. However, if a callback is already executing in flight in another process, detaching does not wait for or abort that in-flight execution.
- **Uncatchable VM Exits**: Abrupt process exits or untrappable signals (`kill`) bypass cleanup hooks.
- **Storage Migration**: Handlers initially live in ETS tables. Calling `:telemetry.persist/0` compiles them into `persistent_term` for read-optimized lookup without interrupting event delivery.
- **No In-Core Export or Buffering**: `sinal` is an in-process telemetry delivery facade. Network export (OTLP, StatsD, Prometheus) and batch buffering belong in dedicated adapter processes.

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

# sinal

Sinal emits and observes typed telemetry events on Erlang/BEAM. Measurements and metadata stay as Gleam values; Erlang and Elixir handlers receive ordinary `:telemetry` names and maps.

## Use this checkout

This is the initial unreleased API. In a consumer beside the Sinal checkout, add a local dependency:

```toml
[dependencies]
sinal = { path = "../sinal" }
```

Sinal requires Gleam 1.18 or newer and telemetry 1.4.2 or a later 1.x. Telemetry is included as a dependency. `attach`, `observe` and `with_subscriptions` start its OTP application when needed.

## Observe an event

Import `sinal` and `sinal/fields`, then define an event, observe it, emit a value and detach the handler:

```gleam
pub fn observe_request_example() {
  let finished =
    sinal.event(
      ["request", "finished"],
      fields.int("duration_ms"),
      fields.string("route"),
    )
  let attachment =
    sinal.observe(finished, fn(_duration_ms, _route) {
      // Runs in the emitting process, before `emit` returns.
      Nil
    })
  sinal.emit(finished, 42, "/users")
  let assert Ok(Nil) = sinal.detach(attachment)
}
```

An `Event(measurements, metadata)` binds a native event name to two field codecs. `observe` returns an `Attachment` with a fresh handler id. Reuse the event definition in producers and observers.

Without a matching route, handlers run in the emitting process before `emit` returns. Native telemetry catches callback errors, exits and throws, removes the failed registration and emits `[telemetry, handler, failure]`. Untrappable termination can still stop that process. A malformed native map skips one invocation; the handler stays attached when failure reporting returns normally.

## Defaults and ownership

| Operation                | Default                                                                                         |
| ------------------------ | ----------------------------------------------------------------------------------------------- |
| Unrouted emission        | Synchronous; a slow handler blocks the emitter, with no handler timeout                         |
| Routed emission          | Returns without waiting for handlers; full or unavailable destinations drop and count the event |
| Forwarder capacity       | 1,024 events, including queued and executing events; `with_capacity(n)` changes it              |
| Forwarder lifecycle      | Application-owned name and supervision; 1,000 ms initialization limit; shutdown does not drain  |
| Native attach and detach | Synchronous registry calls with the native default 5,000 ms timeout                             |
| Native map decoding      | Declared keys only; extra keys ignored; no map-size bound                                       |

Names and field keys become permanent BEAM atoms. Each segment must match `[a-z][a-z0-9_]{0,62}`. Write them in source code; never build them from input. Invalid definitions panic at construction. Payload bytes, name counts, route counts and handler execution time are unbounded.

## More examples

The examples below are compiled and exercised by [readme_example_test.gleam](test/readme_example_test.gleam). The public modules document the full API: [events and subscriptions](src/sinal.gleam), [fields](src/sinal/fields.gleam), [correlation](src/sinal/correlation.gleam), [spans](src/sinal/span.gleam) and [forwarding](src/sinal/forwarder.gleam).

<details>
<summary>Records, enums and optional fields</summary>

A record codec uses `fields.include` to bind decoded fields by name and `fields.success` to build the record. The constructor labels preserve field meaning even when two fields have the same type or appear in a different order.

```gleam
pub type HttpMeasurements {
  HttpMeasurements(duration_ms: Int, bytes_sent: Int)
}

pub type Method {
  Get
  Post
}

pub type HttpMetadata {
  HttpMetadata(method: Method, route: String, status: Int)
}

pub fn http_request_event() -> sinal.Event(HttpMeasurements, HttpMetadata) {
  let measurements = {
    use duration_ms <- fields.include(fields.int("duration_ms"), get: fn(m) {
      m.duration_ms
    })
    use bytes_sent <- fields.include(fields.int("bytes_sent"), get: fn(m) {
      m.bytes_sent
    })
    fields.success(HttpMeasurements(duration_ms:, bytes_sent:))
  }

  let metadata = {
    use method <- fields.include(
      fields.enum("method", [Get, Post], method_name),
      get: fn(m) { m.method },
    )
    use route <- fields.include(fields.string("route"), get: fn(m) { m.route })
    use status <- fields.include(fields.int("status"), get: fn(m) { m.status })
    fields.success(HttpMetadata(method:, route:, status:))
  }

  sinal.event(["http", "server", "request"], measurements, metadata)
}

fn method_name(method: Method) -> String {
  case method {
    Get -> "get"
    Post -> "post"
  }
}
```

Getters need no type annotations when passed with `get:`. Nested record codecs flatten their keys into the same map. Sinal also runs the builder with placeholder values to collect keys, so keep the block to `include` calls and a `success` constructor with pure getters and decoders.

`fields.enum` maps a closed set of values to names. An exhaustive naming function does not prove that its value list is complete. An unlisted value is still emitted for native observers, but Sinal logs a warning and a handler using that enum skips the incompatible invocation. Test every constructor:

```gleam
pub fn every_method_is_listed_test() {
  let metadata = sinal.metadata_fields(http_request_event())
  // One entry per constructor of Method.
  list.each([Get, Post], fn(method) {
    let sample = HttpMetadata(method:, route: "/", status: 200)
    let assert Ok(Nil) = fields.check(metadata, sample)
    let assert Ok(decoded) =
      fields.decode(metadata, fields.encode(metadata, sample))
    assert decoded == sample
  })
}
```

`measurement_fields` and `metadata_fields` expose an event's codecs for `fields.check`, `fields.encode`, `fields.decode` and wire-format tests. `fields.field` accepts a custom encoder and dynamic decoder. Encoding has no typed error return; custom callbacks can still raise.

`fields.optional(inner)` requires a one-key field. `None` omits the key; a missing key or native `nil` or `undefined` decodes as `None`. Other values decode through `inner`, so its present values must not use those absence markers.

</details>

<details>
<summary>Shared correlation values</summary>

A `Correlation` identifies one unit of work across package observations. It is an opaque string of 1 to 128 bytes, carried under the metadata key `correlation`.

```gleam
pub type CheckoutMetadata {
  CheckoutMetadata(cart: String, correlation: Option(Correlation))
}

pub fn checkout_event() -> sinal.Event(Nil, CheckoutMetadata) {
  let metadata = {
    use cart <- fields.include(fields.string("cart"), get: fn(m) { m.cart })
    use correlation <- fields.include(correlation.field(), get: fn(m) {
      m.correlation
    })
    fields.success(CheckoutMetadata(cart:, correlation:))
  }
  sinal.event(["shop", "checkout"], fields.empty(), metadata)
}

pub fn checkout(cart: String, request_id: String) -> Nil {
  // An id from an untrusted header: `from_string` bounds it to 128 bytes.
  let correlation = case correlation.from_string(request_id) {
    Ok(id) -> id
    Error(_) -> correlation.unique()
  }
  sinal.emit(
    checkout_event(),
    Nil,
    CheckoutMetadata(cart:, correlation: Some(correlation)),
  )
}
```

| Constructor                      | Use                                                                                                                |
| -------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `correlation.from_string(value)` | Preserve external input verbatim; refuse an empty or oversized value                                               |
| `correlation.from_key(key)`      | Derive a stable value from an application key; keep a key that fits, otherwise use its 64-character SHA-256 digest |
| `correlation.unique()`           | Generate 128 random bits as 32 lowercase hexadecimal characters                                                    |

Libraries use `correlation.field()` for `Option(Correlation)`: `None` omits the key. Application events that always supply a value can use `correlation.required_field()`:

```gleam
pub type TicketMetadata {
  TicketMetadata(ticket: Correlation, queue: String)
}

pub fn ticket_metadata() -> fields.Fields(TicketMetadata) {
  use ticket <- fields.include(correlation.required_field(), get: fn(m) {
    m.ticket
  })
  use queue <- fields.include(fields.string("queue"), get: fn(m) { m.queue })
  fields.success(TicketMetadata(ticket:, queue:))
}
```

Both fields share one encoding. An optional reader accepts a required value as `Some(correlation)`; a required reader rejects missing or invalid values and skips that invocation. Match the producer's possibility of absence. Copy the correlation into each work-scoped event and dependency call, including events from helper processes. Its cardinality is unbounded: never use it as a metric tag.

</details>

<details>
<summary>Fallible handlers, labels and stable ids</summary>

A `Subscription` describes a registration; `attach` installs it until `detach`. `sinal.handler` handles several events with the same measurement and metadata types and reports typed failures:

```gleam
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
```

`MalformedMeasurements` and `MalformedMetadata` skip one invocation and retain the handler when `on_failure` returns. `HandlerReturned(error)` or a callback exception removes the whole registration. `subscription(event, run)` describes the infallible one-event form of `observe`; both log malformed-map warnings.

`with_label` and `observe_labelled` give fresh handler ids a readable label in `:telemetry.list_handlers/1`. Labels need not be unique. `with_id` instead sets a stable binary id that native code can detach; `attach` returns `AlreadyExists(id)` while that id is in use. Startup and registry failures can raise independently of duplicate-id refusal.

`detach` returns `Error(Nil)` if the registration is already absent. Detach removes future selection, but does not wait for a callback already selected in another process. Reusing a stable id also lets an old attachment detach its replacement.

</details>

<details>
<summary>Scoped subscriptions and cleanup failures</summary>

`with_subscriptions` owns registrations for the duration of one function call:

```gleam
pub fn count_requests(
  event: sinal.Event(HttpMeasurements, HttpMetadata),
  work: fn() -> a,
) -> Result(sinal.SubscriptionCompletion(a), sinal.SubscriptionScopeError) {
  let seen = process.new_subject()
  let observer = sinal.subscription(event, fn(_, _) { process.send(seen, Nil) })
  // Attached before `work` runs and detached when it returns or raises.
  sinal.with_subscriptions(sinal.subscriptions([observer]), work)
}
```

Subscriptions attach in list order and receive cleanup attempts in reverse order. An attachment refusal skips work and returns `SubscriptionAttachFailed(index:, error:, rollback_failures:)`. Normal completion returns `SubscriptionCompletion(work_result:, cleanup_failures:)`.

A catchable work error, exit or throw triggers cleanup attempts and is re-raised with its original class, reason and stacktrace. `with_exception_cleanup_reporter` receives accompanying cleanup failures; a reporter exception cannot replace the work exception. A killed process skips cleanup.

Installation is not atomic and names remain node-wide. A scope neither isolates a request's emissions nor waits for callbacks selected by another process. Keep captured resources valid until those callbacks finish. Install shared application observers at startup.

</details>

<details>
<summary>Native spans and timing</summary>

`sinal/span` emits native start, stop and exception events around one work call:

```gleam
pub fn traced_query(sql: String) -> List(String) {
  let query =
    span.define(
      ["db", "query"],
      start_metadata: fields.string("sql"),
      stop_measurements: fields.empty(),
      stop_metadata: fields.int("rows"),
    )
  span.run(query, sql, fn() {
    let rows = ["row for " <> sql]
    span.Completion(
      result: rows,
      measurements: Nil,
      metadata: list.length(rows),
    )
  })
}
```

`span.events(query)` returns the three typed events for `observe` or `handler`. A normal work value, including a returned application error, produces a stop event with the completion's measurements and metadata. A catchable exception emits the exception event and is re-raised unchanged.

`duration_in`, `system_time_in` and `monotonic_time_in` read timing fields in an explicit `TimeUnit`. A native span context identifies one invocation; it does not supply trace parentage. Spans run in one process and ignore forwarding routes.

</details>

<details>
<summary>Supervised forwarding and prefix routes</summary>

The application can move a library's handler execution into a supervised forwarder. Register the route once at application startup:

```gleam
pub fn isolate_library(name: process.Name(forwarder.Message)) -> Nil {
  let observations = forwarder.new(name)
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(forwarder.supervised(observations))
    |> static_supervisor.start
  // Every `sinal.emit` of an event named `my_library..` now returns as soon
  // as the event is handed to the forwarder.
  forwarder.route(["my_library"], observations)
}
```

The longest matching prefix wins; `[]` matches every event. Routing a prefix again replaces its destination. `unroute(prefix)` exposes a shorter matching route or restores synchronous delivery. Routes live in `persistent_term`, so changes are node-wide updates and belong at startup or shutdown.

A routed refusal drops and counts the event; it never falls back to inline execution. Handlers run in the forwarder process, without the emitter's process-dictionary context. A package that owns its forwarder can inspect a typed refusal directly:

```gleam
pub fn emit_owned(
  observations: forwarder.Forwarder,
  event: sinal.Event(Int, Nil),
) -> Nil {
  case forwarder.emit(observations, event, 1, Nil) {
    Ok(Nil) -> Nil
    // Dropped and counted in the forwarder's `dropped_event`.
    Error(forwarder.CapacityExceeded) -> Nil
    Error(forwarder.ForwarderUnavailable) -> Nil
  }
}
```

`forwarder.new(name)` uses the 1,024-event capacity; `with_capacity(n)` changes it and `supervised` returns its child specification. A capacity below one or an existing ETS table with the same name makes startup fail with `InitFailed`. Create each `process.Name` once at application startup: its diagnostic counters live for the node's lifetime.

`dropped_event()` exposes `[sinal, forwarder, dropped]` with `Dropped(rejected:, lost:, unavailable:)`. Reports are coalesced and bypass routes. Shutdown does not drain; a later incarnation reports an estimate of lost in-flight events. Reports are best effort, and counts are diagnostics rather than delivery receipts.

Admission capacity belongs to one incarnation, including queued and executing events. Delayed producers cannot enqueue into a replacement. Concurrent increment-then-check admission can refuse a send that would fit under a different ordering. Admitted events keep per-producer FIFO order for one destination; events split across routes or route changes have no relative-order guarantee.

</details>

## Operational limits

Native telemetry leaves handler order unspecified. Catchable callback failures are isolated, but an exit signal or untrappable kill can still terminate the process running the handler.

Sinal dispatches within one BEAM node. Export, aggregation, durable buffering and confirmed delivery require an integration with its own capacity and shutdown policy. Native `:telemetry.persist/0` remains available through an application FFI after attaching long-lived handlers; Sinal supplies no wrapper for it.

The supported target is Erlang/BEAM. CI uses Gleam 1.18.1, OTP 28 and telemetry 1.4.2. JavaScript is unsupported.

## Development

```sh
nix develop
gleam test
gleam run -m benchmark
```

Run commands from the package root. [Testing guidance](docs/testing.md) covers focused native checks, stress tests, forwarder race probes, documentation and benchmark reproduction.

One local run on 2026-10-06 measured 392 ns per zero-handler emission and 1,139 ns per synchronous one-handler emission. [Benchmark results](docs/benchmarks/README.md) retain the complete workloads, iteration counts, runtime and raw receipt; these are harness averages from one run.

The [design](docs/design/design-layer.pdf), [source](docs/design/design.typ), [vocabulary](docs/design/CONTEXT.typ), [coverage](docs/COVERAGE.md) and [ADRs](docs/adr/0001-use-the-native-telemetry-registry.md) describe the maintained contracts and their rationale.

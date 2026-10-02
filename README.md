# sinal

A strongly-typed take on Erlang `:telemetry`, built for Gleam's generics instead of dynamic maps and atoms.

`sinal` wraps native BEAM `:telemetry` (1.4.2 or a later 1.x). You describe an event once, with typed codecs for its measurements and metadata, and then emit and observe Gleam values. Erlang and Elixir code sees ordinary telemetry events with atom names and maps.

```toml
[dependencies]
sinal = ">= 0.1.0 and < 1.0.0"
```

`telemetry` (`>= 1.4.2 and < 2.0.0`) comes with sinal; an application does not declare it. `attach`, `observe` and `with_subscriptions` start the `telemetry` OTP application when it is not running.

## The common path

Define an event, observe it, emit it, and detach:

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

`sinal.event` takes the native event name and one codec for the measurements and one for the metadata. `observe` attaches a handler with a fresh handler id and returns its `Attachment`. `emit` encodes the values and runs every attached handler in the caller before it returns. Nothing a handler does crashes the emitter. A native map that does not decode skips that one invocation and leaves the handler attached; `observe` logs a warning that names the event and the field. A crashing handler is removed, and telemetry emits its `[telemetry, handler, failure]` event.

## Defaults

| Operation                                  | Default                                                                                                 |
| ------------------------------------------ | ------------------------------------------------------------------------------------------------------- |
| Handler run inside `emit`                  | Synchronous in the emitting process, with no timeout; a slow handler blocks the emitter                 |
| `emit` of a routed event                   | Handed to the route's forwarder; never waits; dropped and counted when the forwarder is full or down    |
| Forwarder capacity (queued plus executing) | 1,024 events (`forwarder.default_capacity`); `forwarder.with_capacity(n)`; below 1 fails the start      |
| Forwarder initialisation                   | 1,000 ms                                                                                                |
| Forwarder shutdown                         | No drain; in-flight events are lost and reported as `Dropped(lost:)` by the next incarnation            |
| Drop reporting                             | Coalesced per drain; counters shared by every `Forwarder` of one name and kept for the life of the node |
| Routes                                     | No limit on count; stored in `persistent_term`, so each change is a node-wide update                    |
| `attach` / `observe` / `detach`            | A `gen_server` call to native telemetry with its default 5,000 ms timeout                               |
| Handler ids                                | Fresh for every attachment; `with_id` sets a stable one                                                 |
| Event names and field keys                 | Atoms; each segment must match `[a-z][a-z0-9_]{0,62}`; a definition that breaks it panics               |
| Correlation size                           | 1 to 128 bytes, checked by `correlation.from_string` and when the field decodes                         |
| Decoding a native map                      | Reads declared keys only; other keys are ignored; no size bound                                         |
| A native map that does not decode          | Skips that one invocation; the handler stays attached; `on_failure` gets it, `observe` logs a warning   |

Synchronous dispatch is the only unbounded default, and sinal cannot bound it: native telemetry runs handlers inline. An application bounds it by routing a library's events to a forwarder (see [Isolating a library's events](#isolating-a-librarys-events)).

## Names are atoms

Every event name segment and field key becomes an atom of the native event, and the BEAM never frees an atom. Sinal checks each one against `[a-z][a-z0-9_]{0,62}` when the event or codec is defined, so a URL, an email address or a name with spaces fails at definition instead of growing the atom table. The check does not stop a deliberate `"tenant_" <> id`: write names and keys in source code, never build them from input.

A definition that breaks a rule is a programmer error, so the constructor panics with a message that names the offending value: an invalid segment or key, an empty event name, a key declared twice in one record, an `optional` over anything but one key, an `enum` with no values or a repeated name, a span key the span protocol owns, an empty `with_id`, or one event listed twice in `handler`. Any test that builds the definition catches it. Sinal has no fallible constructor for names built at run time, because such names would create atoms from data.

## Records as measurements and metadata

`fields.record` builds the codec of a record, one line per field. `fields.enum` covers a closed set of values, and `fields.field` covers anything else with an encoder and a `gleam/dynamic/decode` decoder:

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
  let measurements =
    fields.record({
      use duration_ms <- fields.parameter
      use bytes_sent <- fields.parameter
      HttpMeasurements(duration_ms:, bytes_sent:)
    })
    |> fields.and(fields.int("duration_ms"), fn(m: HttpMeasurements) {
      m.duration_ms
    })
    |> fields.and(fields.int("bytes_sent"), fn(m) { m.bytes_sent })
    |> fields.build

  let metadata =
    fields.record({
      use method <- fields.parameter
      use route <- fields.parameter
      use status <- fields.parameter
      HttpMetadata(method:, route:, status:)
    })
    |> fields.and(
      fields.enum("method", [Get, Post], method_name),
      fn(m: HttpMetadata) { m.method },
    )
    |> fields.and(fields.string("route"), fn(m) { m.route })
    |> fields.and(fields.int("status"), fn(m) { m.status })
    |> fields.build

  sinal.event(["http", "server", "request"], measurements, metadata)
}

fn method_name(method: Method) -> String {
  case method {
    Get -> "get"
    Post -> "post"
  }
}
```

Only the first getter needs a type annotation, because the record type is not known until `build`.

The compiler checks that `method_name` covers every `Method`, but not that the list `[Get, Post]` does. A constructor missing from the list compiles; when it is emitted, the emit call logs a warning naming the event and the value, and every sinal handler of the event reports `MalformedMetadata`, skips that event and stays attached. Keep the list next to the type, and test that each constructor round-trips through `fields.encode` and `fields.decode`. `fields.optional(inner)` makes a one-key field absent-able: `None` omits the key, and a missing key or the atom `nil` or `undefined` decodes as `None`. Encoding never fails. `fields.encode` and `fields.decode` expose the native map, which is useful to pin a package's wire format in its tests.

## Correlation

`sinal/correlation` defines the value that follows one unit of work across packages: an opaque string of 1 to 128 bytes, carried as the `correlation` key of event metadata.

```gleam
pub type CheckoutMetadata {
  CheckoutMetadata(cart: String, correlation: Option(Correlation))
}

pub fn checkout_event() -> sinal.Event(Nil, CheckoutMetadata) {
  let metadata =
    fields.record({
      use cart <- fields.parameter
      use correlation <- fields.parameter
      CheckoutMetadata(cart:, correlation:)
    })
    |> fields.and(fields.string("cart"), fn(m: CheckoutMetadata) { m.cart })
    |> fields.and(correlation.field(), fn(m) { m.correlation })
    |> fields.build
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

Any application id of 1 to 128 bytes works; `from_string` returns `CorrelationTooLong` for a longer one, and `correlation.field()` refuses to decode one. Derive a longer id, such as one joined from publisher input, into a stable value that fits: a SHA-256 digest from `gleam_crypto` is 64 hexadecimal characters (see [the migration guide](docs/migration-wave-2.md#sinalcorrelation-new) for a snippet). `correlation.unique()` returns 128 random bits as 32 lowercase hexadecimal characters, the shape of a W3C trace id; a trace id is itself a valid correlation. `correlation.field()` omits the key for `None`, and an Erlang or Elixir handler reads `metadata.correlation` as a UTF-8 binary. A package with work-scoped events puts `correlation: Option(Correlation)` in their metadata, copies it into every event of the work, and passes it to the packages it calls. A correlation has unbounded cardinality: never use it as a metric tag.

## Handlers

`observe` covers an infallible handler of one event. A `Subscription` describes any other registration, and `attach` installs it until `detach`:

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

- `sinal.subscription(event, run)` is the `Subscription` form of `observe`.
- `sinal.handler(events, run, on_failure)` registers one handler for several events of the same shape. `run` receives the event that fired and may return an error. `on_failure` receives a `HandlerFailure`. After `MalformedMeasurements` or `MalformedMetadata`, the handler skips that one event and stays attached. After `HandlerReturned`, or a crash, telemetry removes the handler and emits `[telemetry, handler, failure]`.
- `sinal.subscription` and `observe` have no `on_failure`: they log a warning for a malformed native map, skip the event and stay attached.
- `sinal.with_id(subscription, id)` replaces the fresh handler id with a stable binary id, so Erlang or Elixir code can detach it. `attach` returns `AlreadyExists(id)` while another handler holds the id.
- `detach` returns `Error(Nil)` when the handler was no longer attached, for example because telemetry removed it after it crashed or returned an error.

## Scoped subscriptions

`with_subscriptions` attaches a group of subscriptions for the duration of one function call:

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

Subscriptions attach in list order and detach in reverse order. When one fails to attach, the work does not run, the earlier ones are detached, and `SubscriptionAttachFailed(index:, error:, rollback_failures:)` names it. When the work raises (error, exit or throw), every subscription is detached and the exception is re-raised with its class, reason and stacktrace; `with_exception_cleanup_reporter` reports cleanup failures that happen meanwhile. A completed run returns `SubscriptionCompletion(work_result:, cleanup_failures:)`. Attaching is not atomic, so a concurrent emitter can see a partial set, and a killed process skips cleanup.

## Native spans

`sinal/span` wraps work in native telemetry's start, stop and exception events:

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

`span.events(query)` returns the three typed events for `observe` or `handler`. The stop event carries the extra measurements and metadata of the `Completion`; a raised exception emits the exception event and is re-raised unchanged. `duration_in`, `system_time_in` and `monotonic_time_in` read the timing fields in an explicit `TimeUnit`. A span runs in one process and ignores forwarder routes.

## Isolating a library's events

Handlers run inside `emit`, so a slow handler of a library's events slows the library. The application isolates the library with one supervised forwarder and one route, once, at start:

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

From then on, every `sinal.emit` of an event whose name starts with `my_library` hands the event to the forwarder's process and returns. A full or stopped forwarder drops the event and counts it; the forwarder reports the counts in its own `[sinal, forwarder, dropped]` event (`forwarder.dropped_event()`, measurements `Dropped(rejected:, lost:, unavailable:)`). The library itself changes nothing: it emits with `sinal.emit` either way.

- **Longest prefix wins.** `[]` routes every event. Routing a prefix again replaces its forwarder; `forwarder.unroute(prefix)` restores synchronous delivery.
- **The handler's `self()` is the forwarder.** Process-dictionary context from the emitter is not carried across the hop.
- **No loops.** A forwarder's drop report and native spans ignore routes.

Sinal ships no default forwarder application: the application owns the forwarder's name, capacity and supervision.

## A package that owns its forwarder

A package that runs its own forwarder, one per database for example, emits to it directly and sees the refusal:

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

`forwarder.new(name)` holds 1,024 events; `forwarder.with_capacity(n)` changes that. `forwarder.supervised(forwarder)` returns a `ChildSpecification(Forwarder)`. Create the `process.Name` once at application start: every `Forwarder` built from one name shares its drop counters, which live for the life of the node.

## Operational limits

- **Unspecified handler order.** When several handlers are attached to one event, native telemetry calls them in an unspecified order.
- **Detach does not wait.** Detaching stops later deliveries but does not wait for, or interrupt, a handler already running in another process.
- **Uncatchable exits bypass cleanup.** A killed process skips scoped cleanup.
- **Handler storage.** Native telemetry keeps handlers in an ETS table. Sinal has no wrapper for `:telemetry.persist/0`; an application that wants it declares `@external(erlang, "telemetry", "persist")` and calls it after attaching its long-lived handlers.
- **No export or unbounded buffering.** Sinal delivers in process. Export (OTLP, StatsD, Prometheus) belongs in a separate adapter. The forwarder is a bounded, best-effort hop, not a queue.
- **Forwarder delivery is best-effort and per-producer FIFO.** A send beyond capacity or to a stopped forwarder is dropped and counted, never retried. One producer's events to one forwarder keep their order; events split across routes, or across a route change, do not.
- **A handler's exit can stop the forwarder.** Native telemetry isolates a handler that raises, but not one that receives an exit signal.
- **Capacity belongs to one incarnation.** A restarted forwarder starts with fresh admission counters, and a delayed producer cannot enqueue into the replacement. An existing ETS table with the forwarder's name, or a capacity below 1, makes the start fail with `InitFailed`.
- **Admission is one atomic increment.** It never admits past capacity, but under concurrent load at the boundary it can refuse a send that would have fit under another ordering.

## Target and support

| Target            | Status                        | Notes                                                                                         |
| :---------------- | :---------------------------- | :-------------------------------------------------------------------------------------------- |
| **Erlang / BEAM** | **Initial release candidate** | CI uses Gleam 1.18.1 and Erlang/OTP 28 with `:telemetry` 1.4.2.                               |
| **JavaScript**    | **Unsupported**               | `:telemetry` relies on BEAM ETS tables, `persistent_term`, process mailboxes and atom tables. |

## Development, tests and benchmarks

```sh
nix develop                  # reproducible dev shell
gleam test                   # unit, README and stress tests
gleam run -m benchmark       # microbenchmarks
gleam run -m stress_test     # standalone stress test
python3 dev/check_forwarder.py   # synchronized forwarder start and restart races
```

The README's Gleam snippets are copied verbatim from `test/readme_example_test.gleam`, which compiles and runs them.

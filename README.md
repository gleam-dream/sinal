# sinal

Sinal emits and observes typed telemetry events on Erlang/BEAM. Measurements and metadata stay as Gleam values; Erlang and Elixir handlers receive ordinary `:telemetry` names and maps.

## Install

Sinal is unreleased. In a consumer beside this checkout, add a local dependency:

```toml
[dependencies]
sinal = { path = "../sinal" }
```

Sinal requires Gleam 1.18 or newer and telemetry 1.4.2 or a later 1.x. Telemetry is a dependency, and `attach`, `observe` and `with_subscriptions` start its OTP application when needed. The supported target is Erlang/BEAM.

## Observe an event

Import `sinal` and `sinal/fields`, then define an event, observe it, emit a value and detach the handler:

<!-- prettier-ignore-start -->

<!-- snips: examples/usage/src/usage/observe.gleam#observe-request -->
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

<!-- prettier-ignore-end -->

An `Event(measurements, metadata)` binds a native event name to two field codecs. `observe` returns an `Attachment` with a fresh handler id. Reuse the event definition in producers and observers.

Without a matching route, handlers run in the emitting process before `emit` returns. Native telemetry removes a handler whose callback raises and emits `[telemetry, handler, failure]`; a malformed native map skips one invocation and keeps the handler.

Event names and field keys become permanent atoms, so write them in source code and never build them from input. Each segment matches `[a-z][a-z0-9_]{0,62}`, and an invalid definition panics at construction.

## Records and enums

A record codec binds decoded fields by name with `fields.include` and builds the record with `fields.success`:

<!-- prettier-ignore-start -->

<!-- snips: examples/usage/src/usage/records.gleam#records-and-enums -->
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

<!-- prettier-ignore-end -->

An exhaustive naming function does not prove that an enum's value list is complete, so test every constructor with `fields.check`, `fields.encode` and `fields.decode`.

## Forwarding

An application can move handler execution into a supervised forwarder and route an event-name prefix to it once at startup:

<!-- prettier-ignore-start -->

<!-- snips: examples/usage/src/usage/forwarding.gleam#forward-library -->
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

<!-- prettier-ignore-end -->

A full or unavailable forwarder drops and counts the event and never falls back to inline execution. Forwarding is best effort and gives no delivery receipt.

## More

The snippets above come from [compiled, runnable examples](examples/usage/README.md) that also cover fallible handlers with stable ids, subscription scopes, spans, correlation values and a package-owned forwarder; the fast gate runs them, so they match the library. The public modules document the full API: [events and subscriptions](src/sinal.gleam), [fields](src/sinal/fields.gleam), [correlation](src/sinal/correlation.gleam), [spans](src/sinal/span.gleam) and [forwarding](src/sinal/forwarder.gleam).

The [design](docs/design/design.typ), its [context map](docs/CONTEXT-MAP.md), [coverage](docs/COVERAGE.md) and [decisions](docs/adr/0001-dispatch-through-the-shared-native-telemetry-registry.md) describe the maintained contracts and their rationale. The [native telemetry oracle](docs/ORACLE.md) pins the reference that behavior is compared against, and the [benchmarks](docs/BENCHMARKS.md) record local measurements. Commands for development and validation are in [AGENTS.md](AGENTS.md).

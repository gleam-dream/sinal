# Migrating to the wave 2 sinal API

This guide lists every public item that wave 2 of the release plan removed or
changed, with its replacement. It is grouped by module. The commits are
`1ff1c18` (API redesign), `355b100` (telemetry start) and `43279b3`
(`sinal/correlation`).

Three rules cover most edits:

1. **Names and keys are strings.** Drop every `atom.create`: write
   `["http_gun", "request", "stop"]` and `fields.int("status")`. Each segment
   and key must match `[a-z][a-z0-9_]{0,62}`; all literal names in the
   dependents already do.
2. **Definitions are total.** `sinal.event`, `span.define`, `fields.optional`,
   `forwarder.new` and the record builder return the value, not a `Result`.
   Delete the `let assert Ok(..)`. A definition bug panics with a message
   naming the key.
3. **Emission returns `Nil` and ids are automatic.** Delete
   `let assert Ok(Nil) =` and `let _ =` around `sinal.emit`, and delete every
   `sinal.handler_id` call and handler-id helper.

## Dependents' call sites

Counts come from `grep` over `/code/gleam-dream/*/src`, `*/test`,
`*/integrations`, `*/consumers` and `oversight/apps` at the time of the
change.

| Used item (count)                                                                                                              | Replacement                                                             |
| ------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------- |
| `sinal.handler_id` (95), `sinal.HandlerId` (2)                                                                                 | Delete; ids are automatic. `with_id` for a stable native id             |
| `sinal.observe(id, event, run)` (92)                                                                                           | `sinal.observe(event, run)`, returns `Attachment`                       |
| `fields.pair` (81), `fields.imap` (91)                                                                                         | `use x <- fields.include(..)` … `fields.success(..)`                    |
| `sinal.detach` (72)                                                                                                            | Same call; the error is now `Error(Nil)`                                |
| `fields.int` / `string` / `bool` / `empty`                                                                                     | Same, with a `String` key                                               |
| `sinal.emit` (23)                                                                                                              | Same call; returns `Nil`, follows routes                                |
| `sinal.event` (21)                                                                                                             | `sinal.event(List(String), m, d)`, returns `Event`                      |
| `forwarder.emit` (22)                                                                                                          | Same call; error type `Refusal`                                         |
| `forwarder.new` (15), `forwarder.supervised` (15)                                                                              | `forwarder.new(name)` plus `with_capacity`; child data is `Forwarder`   |
| `sinal.attach` (14)                                                                                                            | `sinal.attach(sinal.handler([event], run, on_failure))`                 |
| `sinal.subscription` (11), `subscriptions` (6), `with_subscriptions` (9), `SubscriptionCompletion` (9), `SubscriptionPlan` (2) | Unchanged                                                               |
| `fields.optional` (10)                                                                                                         | Returns `Fields(Option(a))`, no `Result`                                |
| `fields.field` (9), `fields.FieldDecodeError` (13)                                                                             | `fields.field(key, encode, decoder)` or `fields.enum`                   |
| `forwarder.dropped_event` (9), `Dropped`, `DroppedMetadata`                                                                    | Unchanged                                                               |
| `forwarder.route` (4), `forwarder.unroute` (3)                                                                                 | Prefix is `List(String)`                                                |
| `forwarder.emit_routed` (4)                                                                                                    | `sinal.emit`                                                            |
| `sinal.event_native_name` (2), `sinal.event_name` (1)                                                                          | `sinal.name(event)` (strings); map with `atom.create` for native calls  |
| `sinal.encode_event` (1)                                                                                                       | `fields.encode(codec, value)`, or capture the map with a native handler |
| `sinal.AttachError` (2)                                                                                                        | `AlreadyExists(id: String)` is the only variant                         |
| `sinal.HandlerFailure` and its variants (4)                                                                                    | Unchanged                                                               |

`exception.defer` and `exception.rescue` in the dependents come from the
`exception` package, not from sinal.

## `sinal`

### `event`

`event(name: List(Atom), m, d) -> Result(Event, EventError)` becomes
`event(name: List(String), m, d) -> Event`. An empty name or an invalid
segment panics. `EventError` and `EmptyEventName` are removed.

```gleam
// Before
let assert Ok(finished) =
  sinal.event(
    [atom.create("http_gun"), atom.create("request"), atom.create("stop")],
    fields.int(atom.create("duration")),
    fields.empty(),
  )

// After
let finished =
  sinal.event(
    ["http_gun", "request", "stop"],
    fields.int("duration"),
    fields.empty(),
  )
```

A name built from a closed list in code stays a list of strings:

```gleam
// Before (grind/internal/observation/wire.gleam)
pub fn job_event_name(part: String) -> List(atom.Atom) {
  [atom.create("grind"), atom.create("job"), atom.create(part)]
}

// After
pub fn job_event_name(part: String) -> List(String) {
  ["grind", "job", part]
}
```

### `event_name`, `event_native_name`

Both are replaced by `name(event) -> List(String)`.

```gleam
// Before
sinal.event_name(event) |> should.equal(["grind", "diagnostic", part])
native_attach(part, sinal.event_native_name(event), handler)

// After
sinal.name(event) |> should.equal(["grind", "diagnostic", part])
native_attach(part, list.map(sinal.name(event), atom.create), handler)
```

### `emit`

`emit(event, m, d) -> Result(Nil, EmitError)` becomes
`emit(event, m, d) -> Nil`. Encoding cannot fail. `emit` now follows
forwarder routes: when the application routed a prefix of the event's name
with `forwarder.route`, the event runs in that forwarder; otherwise it runs
synchronously, as before. `EmitError` and `EncodingFailed` are removed.

```gleam
// Before
let assert Ok(Nil) = sinal.emit(event, measurements, metadata)
let _ = sinal.emit(event, measurements, metadata)
case sinal.emit(event, m, d) {
  Ok(Nil) -> Nil
  _ -> Nil
}

// After
sinal.emit(event, measurements, metadata)
```

### `encode_event` (was `@internal`)

Removed. To pin a wire format, encode with the event's codec, or attach a
native handler and compare the map it receives.

```gleam
// Before (fabric/test/fabric/observation_test.gleam)
let assert Ok(#(_, raw, _)) =
  sinal.encode_event(o.model_turn(), None, o.ModelTurn("r", 1, o.Retry))
raw |> should.equal(dynamic.properties([]))

// After: encode with the measurements codec the event was built from
fields.encode(o.model_turn_measurements(), None)
|> should.equal(dynamic.properties([]))
```

(`o.model_turn_measurements()` stands for whatever function builds that
codec; expose it from the package or keep a test-only copy.)

### `handler_id`, `HandlerId`, `IdentityError`, `EmptyHandlerId`

Removed. Every attachment gets a fresh id. Delete each app's handler-id
helper. A stable native id, for example so Erlang code can detach the
handler, is `with_id`; an empty id panics.

```gleam
// Before (checkout/telemetry.gleam and every other app)
fn observe(name, event, run) -> Result(sinal.Attachment, sinal.AttachError) {
  let assert Ok(id) = sinal.handler_id("checkout-" <> name)
  sinal.observe(id, event, run)
}

// After
let attachment = sinal.observe(event, run)

// After, with a stable id
let assert Ok(attachment) =
  sinal.attach(sinal.subscription(event, run) |> sinal.with_id("checkout-" <> name))
```

### `observe`

`observe(id, event, run) -> Result(Attachment, AttachError)` becomes
`observe(event, run) -> Attachment`.

```gleam
// Before
let assert Ok(id) = sinal.handler_id("request-finished")
let assert Ok(attachment) = sinal.observe(id, event, fn(m, d) { record(m, d) })

// After
let attachment = sinal.observe(event, fn(m, d) { record(m, d) })
```

### `attach`, `attach_many`, `handler_subscription`

`attach(id, event, handler, on_failure)`, `attach_many(id, first, rest,
handler, on_failure)` and `handler_subscription(id, event, handler,
on_failure)` become one `Subscription` built with `handler(events, run,
on_failure)` and installed with `attach(subscription)`.

```gleam
// Before
let assert Ok(id) = sinal.handler_id("relay-tool")
let assert Ok(attachment) =
  sinal.attach(id, event, fn(_event, m, d) { Ok(Nil) }, fn(_, _) { Nil })

// After
let assert Ok(attachment) =
  sinal.attach(sinal.handler([event], fn(_event, m, d) { Ok(Nil) }, fn(_, _) { Nil }))
```

```gleam
// Before
sinal.attach_many(id, first, [second, third], handler, on_failure)

// After
sinal.attach(sinal.handler([first, second, third], handler, on_failure))
```

```gleam
// Before
sinal.handler_subscription(id, event, handler, on_failure)

// After
sinal.handler([event], handler, on_failure) |> sinal.with_id("my-id")
```

`handler` panics when the list is empty or names one event twice, so
`attach` no longer returns `DuplicateEventName`. With automatic ids `attach`
fails only for a `with_id` id that is taken.

### `with_attachments`, `ScopedCompletion`, `ScopeCleanupFailure`

Removed; use `with_subscriptions`.

```gleam
// Before
sinal.with_attachments(event, [], handler, on_failure, on_cleanup_failure, fn() {
  work()
})
// -> Result(ScopedCompletion(a), AttachError)

// After
sinal.subscriptions([sinal.handler([event], handler, on_failure)])
|> sinal.with_exception_cleanup_reporter(on_cleanup_failure)
|> sinal.with_subscriptions(work)
// -> Result(SubscriptionCompletion(a), SubscriptionScopeError)
```

`ScopedCompletion(work_result:, cleanup_result: Ok(Nil))` corresponds to
`SubscriptionCompletion(work_result:, cleanup_failures: [])`.

### `subscription`, `subscriptions`, `with_subscriptions`, `with_exception_cleanup_reporter`, `SubscriptionPlan`, `SubscriptionCompletion`, `SubscriptionScopeError`

Unchanged in shape. The cleanup failure inside them changed:

```gleam
// Before
sinal.SubscriptionCleanupFailure(0, sinal.DetachReturnedError(sinal.NotAttached))
sinal.SubscriptionCleanupFailure(0, sinal.DetachRaisedException(exception))

// After
sinal.SubscriptionCleanupFailure(0, sinal.AlreadyDetached)
sinal.SubscriptionCleanupFailure(0, sinal.DetachCrashed(description))
```

```gleam
// Before
Error(sinal.SubscriptionAttachFailed(1, sinal.AlreadyExists, []))

// After
Error(sinal.SubscriptionAttachFailed(1, sinal.AlreadyExists("my-id"), []))
```

### `detach`, `DetachError`, `NotAttached`, `DetachBackendNotAvailable`

`detach(attachment) -> Result(Nil, DetachError)` becomes
`detach(attachment) -> Result(Nil, Nil)`; `Error(Nil)` means the handler was
not attached. `DetachError` is removed.

```gleam
// Before
sinal.detach(attachment) |> should.equal(Error(sinal.NotAttached))

// After
sinal.detach(attachment) |> should.equal(Error(Nil))
```

### `AttachError`

`AlreadyExists` gains the id: `AlreadyExists(id: String)`.
`DuplicateEventName` and `BackendNotAvailable` are removed (a repeated event
panics in `handler`; telemetry never returned the other).

```gleam
// Before
Error(sinal.AlreadyExists)

// After
Error(sinal.AlreadyExists("my-id"))
```

### New in `sinal`

- `name(event) -> List(String)`.
- `handler(events, run, on_failure) -> Subscription` and
  `with_id(subscription, id) -> Subscription`.
- `CleanupFailure` (`AlreadyDetached`, `DetachCrashed(description)`).
- `describe_attach_error`, `describe_handler_failure(failure, describe)`,
  `describe_cleanup_failure`, `describe_scope_error`.
- `attach`, `observe` and `with_subscriptions` start the `telemetry` OTP
  application when it is not running. Applications that started it by hand
  (sso_portal) may keep or drop that call.

### Decode failures keep the handler attached

A native map that does not decode no longer detaches the handler. Before,
`dispatch` called `on_failure` and then raised, so telemetry removed the
handler for good and emitted `[telemetry, handler, failure]`; one bad event
silenced every later event of that kind for that subscriber. Now the handler
skips that one invocation and stays attached, in `observe`, `attach`,
`with_subscriptions`, forwarder deliveries and span events alike:

- `handler(events, run, on_failure)`: `on_failure` still receives
  `MalformedMeasurements` or `MalformedMetadata`; telemetry no longer emits
  `[telemetry, handler, failure]` for it.
- `observe` and `subscription`: a `[sinal]`-domain warning names the event
  and the field.
- `HandlerReturned` and a crash in `run` or `on_failure` still remove the
  handler, as before.

Code that waited for a decode failure to detach a handler, or that expected
`detach` to return `Error(Nil)` afterwards, now sees `Ok(Nil)`.

## `sinal/fields`

### Keys

Every constructor takes a `String` key instead of an `Atom`.

```gleam
// Before
fields.int(atom.create("status"))

// After
fields.int("status")
```

### `pair`, `imap`

Removed. Use the record builder (the `use`/`include` form from
[Follow-up: record builder](#follow-up-record-builder); the first wave 2
release had `record`/`parameter`/`and`/`build`).

```gleam
// Before (http_gun/telemetry.gleam style)
let assert Ok(p) =
  fields.pair(fields.string(atom.create("method")), fields.int(atom.create("status")))
fields.imap(p, fn(p) { Request(p.0, p.1) }, fn(r: Request) { #(r.method, r.status) })

// After
use method <- fields.include(fields.string("method"), get: fn(r) { r.method })
use status <- fields.include(fields.int("status"), get: fn(r) { r.status })
fields.success(Request(method:, status:))
```

Nested pairs flatten into one builder:

```gleam
// Before
let assert Ok(ab) = fields.pair(a_field, b_field)
let assert Ok(abc) = fields.pair(ab, c_field)
fields.imap(abc, fn(t) { let #(#(a, b), c) = t  R(a, b, c) }, fn(r: R) { #(#(r.a, r.b), r.c) })

// After
use a <- fields.include(a_field, get: fn(r) { r.a })
use b <- fields.include(b_field, get: fn(r) { r.b })
use c <- fields.include(c_field, get: fn(r) { r.c })
fields.success(R(a:, b:, c:))
```

A one-field wrapper (`imap` over a single field) becomes a one-field record,
or a `field` with `decode.map`:

```gleam
// Before (http_gun/telemetry.gleam:135)
fields.imap(fields.string(atom.create(name)), Id, fn(id) { id.value })

// After
fields.field(name, fn(id: Id) { dynamic.string(id.value) }, decode.string |> decode.map(Id))
```

A duplicate key panics in `include`; `DuplicateField` is removed.

### `field`, `FieldDecodeError`, `FieldEncodeError`

`field(key: Atom, encode: fn(a) -> Result(Dynamic, FieldEncodeError),
decode: fn(Dynamic) -> Result(a, FieldDecodeError))` becomes
`field(key: String, encode: fn(a) -> Dynamic, decoder: decode.Decoder(a))`.
`FieldDecodeError` and `FieldEncodeError` are removed.

```gleam
// Before (warden/observation.gleam style)
fields.field(
  atom.create("attempt"),
  fn(n) { Ok(dynamic.int(n)) },
  fn(raw) {
    case decode.run(raw, decode.int) {
      Ok(n) -> Ok(n)
      Error(_) -> Error(fields.FieldDecodeError("expected an int"))
    }
  },
)

// After
fields.field("attempt", dynamic.int, decode.int)
```

The four string enums (fabric `observation.gleam:677`, grind
`internal/observation/wire.gleam:21`, saga `observation.gleam:230`, http_gun
`telemetry.gleam:143`) become `fields.enum`:

```gleam
// Before
fields.field(atom.create(key), fn(v) { Ok(dynamic.string(to_name(v))) }, fn(raw) {
  case decode.run(raw, decode.string) {
    Ok(name) -> case from_name(name) {
      Ok(v) -> Ok(v)
      Error(_) -> Error(fields.FieldDecodeError("unknown " <> key))
    }
    Error(_) -> Error(fields.FieldDecodeError("expected a string"))
  }
})

// After
fields.enum(key, [First, Second, Third], to_name)
```

`enum` writes the name as a binary and also reads an atom with that text.
A value that needs a tagged tuple or an atom on the wire (http_gun
milestones, warden's method atom and outcome tuple) stays a `field`:

```gleam
// After: an atom on the wire
fields.field(
  "method",
  fn(method) { atom.to_dynamic(atom.create(method_name(method))) },
  atom.decoder()
    |> decode.then(fn(a) {
      case atom.to_string(a) {
        "get" -> decode.success(Get)
        "post" -> decode.success(Post)
        _ -> decode.failure(Get, "get or post")
      }
    }),
)
```

### `optional`, `InvalidOptionalInner`

`optional(inner) -> Result(Fields(Option(a)), FieldError)` becomes
`optional(inner) -> Fields(Option(a))`; an inner field with other than one
key panics.

```gleam
// Before
let assert Ok(nickname) = fields.optional(fields.string(atom.create("nickname")))

// After
let nickname = fields.optional(fields.string("nickname"))
```

### `FieldError`

`MissingField(name:) | DuplicateField(name:) | InvalidField(name:, error:
FieldDecodeError) | InvalidOptionalInner(names:)` becomes
`NotAMap | MissingField(key:) | InvalidField(key:, errors:
List(decode.DecodeError))`.

```gleam
// Before
sinal.MalformedMeasurements(fields.InvalidField("system_time", _))
fields.InvalidField("", fields.FieldDecodeError("Expected a native BEAM map"))

// After
sinal.MalformedMeasurements(fields.InvalidField("system_time", _))
fields.NotAMap
```

### `encode`, `decode`

`encode(fields, value) -> Result(Dynamic, FieldEncodeError)` becomes
`encode(fields, value) -> Dynamic`; `decode` keeps its shape with the new
`FieldError`.

```gleam
// Before
let assert Ok(raw) = fields.encode(codec, value)

// After
let raw = fields.encode(codec, value)
```

### `declared_keys`, `declared_native_keys`

Replaced by `keys(fields) -> List(String)`.

### `enum` values missing from the list

`enum(key, values, name)` cannot check `values` against the type: the
compiler sees that `name` covers every constructor, not that the list does.
A constructor missing from the list compiles and still encodes its name.
`sinal.emit`, `forwarder.emit` and `span.run` then log a `[sinal]`-domain
warning in the emitting process that names the event and the value, and
every sinal handler of the event reports `MalformedMetadata` (or
`MalformedMeasurements`), skips that event and stays attached. Before this
fix the first such event detached every typed handler of the event. The
signature is unchanged; keep the list next to the type and test that each
constructor round-trips.

### New in `sinal/fields`

`float(key)`, `enum(key, values, name)`, `record`, `parameter`, `and`,
`build`, `Record(record, constructor)`, `keys`, `describe_error`.

## `sinal/forwarder`

### `new`, `ConfigError`, `InvalidCapacity`

`new(name, capacity) -> Result(Forwarder, ConfigError)` becomes
`new(name) -> Forwarder` with a capacity of 1,024
(`forwarder.default_capacity`). `with_capacity(forwarder, n)` sets another;
a value below 1 makes the start fail with `actor.InitFailed`. `ConfigError`
is removed.

```gleam
// Before
let assert Ok(fwd) = forwarder.new(process.new_name("research_events"), 4096)

// After
let fwd =
  forwarder.new(process.new_name("research_events"))
  |> forwarder.with_capacity(4096)
```

```gleam
// Before (checkout, extractor, sso_portal: capacity 1024)
let assert Ok(http_observations) =
  forwarder.new(process.new_name("checkout_http_observations"), 1024)

// After
let http_observations = forwarder.new(process.new_name("checkout_http_observations"))
```

Every `Forwarder` built from one `process.Name` now shares its drop
counters.

### `supervised`

`supervised(forwarder) -> ChildSpecification(Nil)` becomes
`ChildSpecification(Forwarder)`. Code that only adds it to a supervisor is
unchanged; code that names the type changes:

```gleam
// Before
fn restart(spec: supervision.ChildSpecification(Nil)) { .. }

// After
fn restart(spec: supervision.ChildSpecification(forwarder.Forwarder)) { .. }
```

### `emit`, `ForwardError`

`emit(forwarder, event, m, d) -> Result(Nil, ForwardError)` keeps its shape
with the closed `Refusal { CapacityExceeded  ForwarderUnavailable }`.
`ForwardEncodingFailed` is removed.

```gleam
// Before
case forwarder.emit(fwd, event, m, d) {
  Ok(Nil) -> Nil
  Error(forwarder.ForwardEncodingFailed(_)) -> panic as "bad event shape"
  Error(forwarder.CapacityExceeded) -> Nil
  Error(forwarder.ForwarderUnavailable) -> Nil
}

// After
case forwarder.emit(fwd, event, m, d) {
  Ok(Nil) -> Nil
  Error(forwarder.CapacityExceeded) -> Nil
  Error(forwarder.ForwarderUnavailable) -> Nil
}
```

### `emit_routed`

Removed: `sinal.emit` follows routes. A library that called `emit_routed`
calls `sinal.emit`; a library that owned a forwarder only to bound its
handlers (http_gun's `observations: Option(Forwarder)`) can emit with
`sinal.emit` and let the application route its prefix.

```gleam
// Before (fabric/internal/observe.gleam:377)
let _ = forwarder.emit_routed(event, measurements, metadata)

// After
sinal.emit(event, measurements, metadata)
```

### `route`, `unroute`

The prefix is `List(String)`; each segment is checked like an event name.

```gleam
// Before
forwarder.route([atom.create("fabric")], fwd)
forwarder.unroute([atom.create("fabric")])

// After
forwarder.route(["fabric"], fwd)
forwarder.unroute(["fabric"])
```

### Unchanged

`Forwarder`, `Message`, `Dropped(rejected:, lost:, unavailable:)`,
`DroppedMetadata(forwarder:)` and `dropped_event()`.

### New in `sinal/forwarder`

`default_capacity`, `with_capacity`, `Refusal`, `describe_refusal`.

## `sinal/span`

### `event_prefix`, `EventPrefix`, `PrefixError`, `prefix_name`, `prefix_native_name`, `define_span`, `SpanDefinitionError`

Replaced by `define(name: List(String), start_metadata:, stop_measurements:,
stop_metadata:) -> Span`. An empty name or a reserved key panics.

```gleam
// Before
let assert Ok(prefix) = span.event_prefix([atom.create("db"), atom.create("query")])
let assert Ok(query) = span.define_span(prefix, start, extra, stop)

// After
let query =
  span.define(
    ["db", "query"],
    start_metadata: start,
    stop_measurements: extra,
    stop_metadata: stop,
  )
```

### `run_span`, `run_span_result`, `SpanOutcome`, `CompletionEncodeError`

Encoding cannot fail, so one runner remains: `run(span, start_metadata,
work) -> a`.

```gleam
// Before
span.run_span(query, sql, work)
let assert span.SpanCompleted(rows) = span.run_span_result(query, sql, work)

// After
span.run(query, sql, work)
```

### `system_time_to_dynamic`, `monotonic_time_to_dynamic`, `duration_to_dynamic`, `span_context_to_dynamic`

Removed. Read timing with `system_time_in`, `monotonic_time_in` and
`duration_in(value, span.Native)`; compare `SpanContext` values with `==`.

### `exception_reason_to_dynamic`, `exception_stacktrace_to_dynamic`

Renamed `reason_to_dynamic` and `stacktrace_to_dynamic`.

### Unchanged

`Span`, `SpanEvents`, `events`, `Completion`, `TimeUnit`, `SystemTime`,
`MonotonicTime`, `NativeDuration`, `SpanContext`, `ExceptionReason`,
`ExceptionStacktrace`, `ExceptionKind`, the measurement and metadata records,
and the time readers.

## `sinal/exception`

Removed. `BeamException`, `ExceptionClass`, `exception_class` and `reraise`
have no replacement; a scope reports a detach crash as
`DetachCrashed(description)`, and work exceptions are still re-raised
unchanged. No dependent imported this module.

## `sinal/correlation` (new)

`Correlation`, `CorrelationError` (`EmptyCorrelation`,
`CorrelationTooLong(bytes:, max_bytes:)`), `max_bytes`, `from_string`,
`unique`, `to_string`, `field` and `describe_error`. Packages with
work-scoped events add `correlation: Option(Correlation)` to their metadata
records and encode it with `correlation.field()`:

```gleam
use route <- fields.include(fields.string("route"), get: fn(m) { m.route })
use correlation <- fields.include(correlation.field(), get: fn(m) {
  m.correlation
})
fields.success(RequestMetadata(route:, correlation:))
```

No sibling package carries `Correlation` yet. Each adopts it in its own
release wave: http_gun in wave 3 (HTTPGUN-R8), when `Correlation` replaces
`telemetry.Id` as the cross-package key and http_gun keeps its per-invocation
`request_id`. Until then, an application can use `Correlation` for its own
events and validate an untrusted id with `correlation.from_string` where the
id enters the application.

`from_string` returns `CorrelationTooLong(bytes:, max_bytes: 128)` for an id
over 128 bytes, and `correlation.field()` refuses to decode one. An id
derived from input, such as `event_id <> ":" <> subscription_id`, can exceed
it. Do not emit `None` for such work: derive a stable value that fits. A
SHA-256 digest is 64 hexadecimal characters, and the same id always gives
the same digest. With `gleam_crypto` in the application's dependencies
(sinal does not depend on it):

```gleam
import gleam/bit_array
import gleam/crypto
import gleam/string
import sinal/correlation.{type Correlation}

/// The id itself when it fits, otherwise its SHA-256 digest as 64 lowercase
/// hexadecimal characters. The same id always gives the same correlation.
pub fn correlation_for(
  id: String,
) -> Result(Correlation, correlation.CorrelationError) {
  case correlation.from_string(id) {
    Error(correlation.CorrelationTooLong(..)) ->
      crypto.hash(crypto.Sha256, bit_array.from_string(id))
      |> bit_array.base16_encode
      |> string.lowercase
      |> correlation.from_string
    result -> result
  }
}
```

## Follow-up: `correlation.required_field()`

`correlation.field()` is `Fields(Option(Correlation))`, which fits a library
whose caller may not have supplied a correlation. An application event that
always has one had to wrap `Some(..)` on emit and handle an unreachable
`None` on read. `correlation.required_field()` is new and removes both. The
existing `field()` is unchanged.

```gleam
// Before: an always-present correlation held as Option.
pub type TicketMetadata {
  TicketMetadata(ticket: Option(Correlation), queue: String)
}
use ticket <- fields.include(correlation.field(), get: fn(m) { m.ticket })
sinal.emit(event, Nil, TicketMetadata(ticket: Some(id), queue:))
// ... and at the reader: case m.ticket { Some(id) -> .. None -> Nil }

// After: required_field() holds the Correlation itself.
pub type TicketMetadata {
  TicketMetadata(ticket: Correlation, queue: String)
}
use ticket <- fields.include(correlation.required_field(), get: fn(m) {
  m.ticket
})
sinal.emit(event, Nil, TicketMetadata(ticket: id, queue:))
```

The two functions use the key `correlation` and the same wire encoding, so
they interoperate: a handler using `field()` (a library's) reads events
emitted with `required_field()` as `Some(correlation)`, and a handler using
`required_field()` reads events emitted with `field()` and `Some`. Decoding a
missing key (an event emitted with `field()` and `None`), an invalid value or
the atom `nil` with `required_field()` fails like any other decode failure:
`MalformedMetadata(MissingField("correlation"))` or `InvalidField`, the call
is skipped and the handler stays attached.

Use `field()` in a library and `required_field()` in an application event
that always has a correlation. Switching a field from one to the other
changes the metadata type but not the wire format, so emitters and handlers
can move independently.

Dependents that use `correlation.field()` on an event that always has one,
and can switch:

- `oversight/apps/support_desk/src/support_desk/events.gleam` (`TicketMetadata`
  line 39, `AnswerMetadata` line 58) and its collector in `telemetry.gleam`
  (the unreachable `None -> Nil` arm).
- `oversight/apps/secure_mcp/src/secure_mcp/telemetry.gleam` (`McpRequest`
  line 54, `ReportSubmitted` line 70).

`oversight/apps/webhooks` keeps `field()`: its delivery correlation is `None`
when the id is too long.

No package under `/code/gleam-dream/*/src` uses `correlation.field()`.

## Follow-up: record builder

The record builder now has the shape of `json/blueprint/codec`'s `field` and
`success`, so the ecosystem has one builder style. The old builder bound each
`fields.and` to the next constructor parameter by position: two fields of one
type listed in another order than the constructor's swapped silently, and the
first getter needed a type annotation. Now each field binds its value by name
in a `use` block, and the getter, passed as `get:` after the rest of the
block, needs no annotation.

| Item                                            | Before                                    | After                                                  |
| ----------------------------------------------- | ----------------------------------------- | ------------------------------------------------------ |
| `fields.record`, `fields.parameter`             | `record({ use x <- parameter ... Ctor })` | Removed; the `use` block is the record                 |
| `fields.and`                                    | `\|> and(field, getter)`                  | `use x <- fields.include(field, get: getter)`          |
| `fields.build`                                  | `\|> build`                               | `fields.success(Ctor(..))` ends the block              |
| `fields.Record` (type)                          | `Record(record, constructor)`             | Removed; every step is a `Fields(r)`                   |
| `fields.include(field, then:, get:)` (new)      |                                           | Adds one field; `field` can be a nested record         |
| `fields.success(value)` (new)                   |                                           | Ends a record; alone it declares no keys, like `empty` |
| `fields.empty`, `keys`, `encode`, `decode`, ... |                                           | Unchanged; `empty()` is `success(Nil)`                 |

```gleam
// Before
pub fn request_metadata() -> fields.Fields(RequestMetadata) {
  fields.record({
    use route <- fields.parameter
    use correlation <- fields.parameter
    RequestMetadata(route:, correlation:)
  })
  |> fields.and(fields.string("route"), fn(m: RequestMetadata) { m.route })
  |> fields.and(correlation.field(), fn(m) { m.correlation })
  |> fields.build
}

// After
pub fn request_metadata() -> fields.Fields(RequestMetadata) {
  use route <- fields.include(fields.string("route"), get: fn(m) { m.route })
  use correlation <- fields.include(correlation.field(), get: fn(m) {
    m.correlation
  })
  fields.success(RequestMetadata(route:, correlation:))
}
```

A record in argument or `let` position becomes a block:

```gleam
// Before
sinal.event(
  ["shop", "checkout"],
  fields.empty(),
  fields.record({
    use cart <- fields.parameter
    Checkout(cart:)
  })
    |> fields.and(fields.string("cart"), fn(m: Checkout) { m.cart })
    |> fields.build,
)

// After
sinal.event(["shop", "checkout"], fields.empty(), {
  use cart <- fields.include(fields.string("cart"), get: fn(m) { m.cart })
  fields.success(Checkout(cart:))
})
```

A one-field record built from a bare constructor
(`fields.record(Ctor) |> fields.and(field, getter) |> fields.build`) becomes
`use x <- fields.include(field, get: getter)` and `fields.success(Ctor(x))`.
A nested record is a field like any other:
`use context <- fields.include(attempt_context_fields(), get: fn(m) { m.context })`.

**Mechanical rule.** For each `fields.record({ use a <- fields.parameter ...
BODY }) |> fields.and(F1, G1) ... |> fields.build`, write
`use a <- fields.include(F1, get: G1)` for the n-th parameter and n-th `and`,
then `fields.success(BODY)`; wrap the result in `{ }` unless it is already
the whole body of a function or block, and run `gleam format`. The getter's
`fn(m: Type)` annotation can go. This keeps today's pairing, so check that
each `use x` now sits next to the field and getter of `x`; a mismatch there
was a silent swap before. In the dependents listed below every name already
matches its getter. A getter passed without its `get:` label fills the
`then` slot and the call fails to compile, so no site changes meaning
silently.

**Behaviour.** The wire output is unchanged: the same keys and values, the
same key order from `fields.keys`, and the same first failing field, in
declaration order, from `decode`. Changed:

- A key declared twice panics with `sinal/fields.include: key "k" is declared
twice in one record` (was `sinal/fields.and: ...`), still where the record
  is defined.
- The record's keys and encoder are fixed when the record is defined, by
  running the `use` block once with placeholder values (each field's zero
  value; `fields.field` runs its decoder against `nil` for it). Keep the block
  to `include` calls and a `success` constructor, and do not choose a field
  from a value bound before it. Decoding runs the block again with the
  decoded values, so decoding a record builds its field codecs once more
  (about 40 ns per field on OTP 28); encoding and emitting cost what they did.

Dependents (every site fails to compile until migrated; line numbers are the
`fields.record` calls at the time of the change):

| Package        | Records | File and lines                                                                                                                               |
| -------------- | ------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| saga           | 10      | `src/saga/observation.gleam` 177, 186, 200, 215, 240, 249, 267, 305, 345, 368                                                                |
| grind          | 29      | `src/grind/observation.gleam` (12) 506–696; `src/grind/diagnostic.gleam` (15) 300–558; `src/grind/internal/observation/wire.gleam` 43, 65    |
| http_gun       | 2       | `src/http_gun/telemetry.gleam` 90, 97                                                                                                        |
| warden         | 2       | `src/warden/observation.gleam` 49, 58                                                                                                        |
| llm_wire       | 1       | `src/llm_wire/telemetry.gleam` 39                                                                                                            |
| relay          | 8       | `src/relay/telemetry.gleam` 51, 66, 81, 101, 108, 125, 135, 150 (three are `fields.record(Ctor)` one-field records)                          |
| fabric         | 21      | `src/fabric/observation.gleam` 299–821                                                                                                       |
| oversight apps | 7       | support_desk `events.gleam` 34, 52; secure_mcp `telemetry.gleam` 48, 65; webhooks `telemetry.gleam` 60, 69; research_agent `events.gleam` 43 |

No dependent uses the builder in `test/`, `integrations/` or `consumers/`.
Prose mentions, not code: `oversight/apps/extractor/FEEDBACK.md`,
`oversight/apps/webhooks/FEEDBACK.md` and
`oversight/docs/release-api/sinal.md`. The rule above, applied to clones of
saga, grind, http_gun, warden, llm_wire, relay and fabric at their current
heads, and of the four apps against the wave 2 heads, compiles with
`--warnings-as-errors`, and every test suite passes unchanged.

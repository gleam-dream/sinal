//// Runs work inside a native telemetry span, which emits typed start, stop
//// and exception events around it.
////
//// Use this module to time a unit of work and report how it ended.
//// `define` names the span and gives `sinal/fields` codecs for its start
//// metadata, its extra stop measurements and its stop metadata. `run` runs
//// the work: `[name.., start]` is emitted before it, then `[name.., stop]`
//// when it returns or `[name.., exception]` when it raises, and the
//// exception is re-raised unchanged. `events` returns the three typed
//// events, so handlers attach with `sinal.observe` or `sinal.handler`.
////
//// ```gleam
//// import sinal/fields
//// import sinal/span
////
//// let query =
////   span.define(
////     ["db", "query"],
////     start_metadata: fields.string("sql"),
////     stop_measurements: fields.empty(),
////     stop_metadata: fields.int("rows"),
////   )
//// let rows =
////   span.run(query, "SELECT 1", fn() {
////     let rows = select("SELECT 1")
////     span.Completion(result: rows, measurements: Nil, metadata: list.length(rows))
////   })
//// ```
////
//// Native telemetry measures the timing fields; `duration_in`,
//// `system_time_in` and `monotonic_time_in` read them in an explicit
//// `TimeUnit`. A span runs in one process: it ignores forwarder routes,
//// because its start and stop must share a process to measure duration.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/list
import gleam/string
import sinal
import sinal/fields
import sinal/internal/ffi
import sinal/internal/name as grammar

/// A wall-clock timestamp in native time units.
pub opaque type SystemTime {
  SystemTime(Int)
}

/// A monotonic timestamp in native time units.
pub opaque type MonotonicTime {
  MonotonicTime(Int)
}

/// A span duration in native time units.
pub opaque type NativeDuration {
  NativeDuration(Int)
}

/// A unit accepted by the Erlang runtime for native time conversion.
pub type TimeUnit {
  Native
  Nanosecond
  Microsecond
  Millisecond
  Second
}

/// The `telemetry_span_context` that links one span's events. Compare two
/// with `==`.
pub opaque type SpanContext {
  SpanContext(Dynamic)
}

/// The reason of the exception that ended a span.
pub opaque type ExceptionReason {
  ExceptionReason(Dynamic)
}

/// The stacktrace of the exception that ended a span.
pub opaque type ExceptionStacktrace {
  ExceptionStacktrace(Dynamic)
}

/// The class of the exception that ended a span.
pub type ExceptionKind {
  ExceptionError
  ExceptionExit
  ExceptionThrow
}

@external(erlang, "sinal_ffi", "convert_native_time")
fn convert_native_time(value: Int, unit: TimeUnit) -> Int

/// Converts a native span duration to `unit`.
pub fn duration_in(duration: NativeDuration, unit: TimeUnit) -> Int {
  let NativeDuration(value) = duration
  convert_native_time(value, unit)
}

/// Converts a native system timestamp to `unit`.
pub fn system_time_in(time: SystemTime, unit: TimeUnit) -> Int {
  let SystemTime(value) = time
  convert_native_time(value, unit)
}

/// Converts a native monotonic timestamp to `unit`.
pub fn monotonic_time_in(time: MonotonicTime, unit: TimeUnit) -> Int {
  let MonotonicTime(value) = time
  convert_native_time(value, unit)
}

/// The exception reason as a native term, which may be any BEAM value.
pub fn reason_to_dynamic(reason: ExceptionReason) -> Dynamic {
  let ExceptionReason(value) = reason
  value
}

/// The exception stacktrace as a native term.
pub fn stacktrace_to_dynamic(stacktrace: ExceptionStacktrace) -> Dynamic {
  let ExceptionStacktrace(value) = stacktrace
  value
}

/// Measurements of `[name.., start]`.
pub type StartMeasurements {
  StartMeasurements(system_time: SystemTime, monotonic_time: MonotonicTime)
}

/// Measurements of `[name.., stop]`: the timing fields and the span's own.
pub type StopMeasurements(extra) {
  StopMeasurements(
    duration: NativeDuration,
    monotonic_time: MonotonicTime,
    extra: extra,
  )
}

/// Measurements of `[name.., exception]`.
pub type ExceptionMeasurements {
  ExceptionMeasurements(duration: NativeDuration, monotonic_time: MonotonicTime)
}

/// Metadata of `[name.., start]`.
pub type StartMetadata(metadata) {
  StartMetadata(metadata: metadata, context: SpanContext)
}

/// Metadata of `[name.., stop]`.
pub type StopMetadata(metadata) {
  StopMetadata(metadata: metadata, context: SpanContext)
}

/// Metadata of `[name.., exception]`: the start metadata and the
/// exception.
pub type ExceptionMetadata(metadata) {
  ExceptionMetadata(
    metadata: metadata,
    context: SpanContext,
    kind: ExceptionKind,
    reason: ExceptionReason,
    stacktrace: ExceptionStacktrace,
  )
}

/// A typed span definition.
pub opaque type Span(start_metadata, extra_measurements, stop_metadata) {
  Span(
    name: List(String),
    start_metadata: fields.Fields(start_metadata),
    stop_measurements: fields.Fields(extra_measurements),
    stop_metadata: fields.Fields(stop_metadata),
  )
}

/// Defines a span. `name` is the prefix of its three events.
///
/// Panics when `name` is empty or breaks the name grammar, or when a codec
/// declares a key the span protocol owns: `duration` and `monotonic_time`
/// in the stop measurements, `telemetry_span_context`, `kind`, `reason` and
/// `stacktrace` in the start metadata, and `telemetry_span_context` in the
/// stop metadata.
pub fn define(
  name: List(String),
  start_metadata start_metadata: fields.Fields(start_metadata),
  stop_measurements stop_measurements: fields.Fields(extra_measurements),
  stop_metadata stop_metadata: fields.Fields(stop_metadata),
) -> Span(start_metadata, extra_measurements, stop_metadata) {
  case name {
    [] -> panic as "sinal/span.define: the span name is empty"
    _ ->
      list.each(name, fn(segment) {
        grammar.to_atom(
          segment,
          caller: "sinal/span.define",
          what: "name segment",
        )
      })
  }
  reject_reserved(stop_measurements, "stop measurement", [
    "duration", "monotonic_time",
  ])
  reject_reserved(start_metadata, "start metadata", [
    "telemetry_span_context", "kind", "reason", "stacktrace",
  ])
  reject_reserved(stop_metadata, "stop metadata", ["telemetry_span_context"])
  Span(name:, start_metadata:, stop_measurements:, stop_metadata:)
}

/// The span's three events.
pub type SpanEvents(start_metadata, extra_measurements, stop_metadata) {
  SpanEvents(
    start: sinal.Event(StartMeasurements, StartMetadata(start_metadata)),
    stop: sinal.Event(
      StopMeasurements(extra_measurements),
      StopMetadata(stop_metadata),
    ),
    exception: sinal.Event(
      ExceptionMeasurements,
      ExceptionMetadata(start_metadata),
    ),
  )
}

/// Returns the typed start, stop and exception events of `span`.
pub fn events(
  span: Span(start_metadata, extra_measurements, stop_metadata),
) -> SpanEvents(start_metadata, extra_measurements, stop_metadata) {
  SpanEvents(
    start: sinal.event(
      list.append(span.name, ["start"]),
      start_measurement_fields(),
      start_metadata_fields(span.start_metadata),
    ),
    stop: sinal.event(
      list.append(span.name, ["stop"]),
      stop_measurement_fields(span.stop_measurements),
      stop_metadata_fields(span.stop_metadata),
    ),
    exception: sinal.event(
      list.append(span.name, ["exception"]),
      exception_measurement_fields(),
      exception_metadata_fields(span.start_metadata),
    ),
  )
}

/// What the work of a span returns: its result, and the stop event's extra
/// measurements and metadata.
pub type Completion(result, extra_measurements, stop_metadata) {
  Completion(
    result: result,
    measurements: extra_measurements,
    metadata: stop_metadata,
  )
}

/// Runs `work` inside the span and returns its result. A raised exception
/// (error, exit or throw) emits the exception event and is re-raised with
/// its class, reason and stacktrace.
pub fn run(
  span: Span(start_metadata, extra_measurements, stop_metadata),
  start_metadata: start_metadata,
  work: fn() -> Completion(a, extra_measurements, stop_metadata),
) -> a {
  ffi.telemetry_span(
    list.map(span.name, atom.create),
    fields.encode_for_emit(
      span.start_metadata,
      start_metadata,
      caller: "sinal/span.run",
      event: fn() { list.append(span.name, ["start"]) },
    ),
    fn() {
      let Completion(result:, measurements:, metadata:) = work()
      #(
        result,
        fields.encode_for_emit(
          span.stop_measurements,
          measurements,
          caller: "sinal/span.run",
          event: fn() { list.append(span.name, ["stop"]) },
        ),
        fields.encode_for_emit(
          span.stop_metadata,
          metadata,
          caller: "sinal/span.run",
          event: fn() { list.append(span.name, ["stop"]) },
        ),
      )
    },
  )
}

fn reject_reserved(
  codec: fields.Fields(a),
  what: String,
  reserved: List(String),
) -> Nil {
  case list.find(fields.keys(codec), list.contains(reserved, _)) {
    Ok(key) ->
      panic as {
        "sinal/span.define: "
        <> what
        <> " key "
        <> string.inspect(key)
        <> " is reserved by the span protocol"
      }
    Error(Nil) -> Nil
  }
}

fn system_time_field() -> fields.Fields(SystemTime) {
  fields.field(
    "system_time",
    fn(time) {
      let SystemTime(value) = time
      dynamic.int(value)
    },
    decode.int |> decode.map(SystemTime),
  )
}

fn monotonic_time_field() -> fields.Fields(MonotonicTime) {
  fields.field(
    "monotonic_time",
    fn(time) {
      let MonotonicTime(value) = time
      dynamic.int(value)
    },
    decode.int |> decode.map(MonotonicTime),
  )
}

fn duration_field() -> fields.Fields(NativeDuration) {
  fields.field(
    "duration",
    fn(duration) {
      let NativeDuration(value) = duration
      dynamic.int(value)
    },
    decode.int |> decode.map(NativeDuration),
  )
}

fn span_context_field() -> fields.Fields(SpanContext) {
  fields.field(
    "telemetry_span_context",
    fn(context) {
      let SpanContext(value) = context
      value
    },
    decode.dynamic |> decode.map(SpanContext),
  )
}

fn start_measurement_fields() -> fields.Fields(StartMeasurements) {
  fields.record({
    use system_time <- fields.parameter
    use monotonic_time <- fields.parameter
    StartMeasurements(system_time:, monotonic_time:)
  })
  |> fields.and(system_time_field(), fn(m: StartMeasurements) { m.system_time })
  |> fields.and(monotonic_time_field(), fn(m) { m.monotonic_time })
  |> fields.build
}

fn stop_measurement_fields(
  extra: fields.Fields(extra),
) -> fields.Fields(StopMeasurements(extra)) {
  fields.record({
    use duration <- fields.parameter
    use monotonic_time <- fields.parameter
    use extra <- fields.parameter
    StopMeasurements(duration:, monotonic_time:, extra:)
  })
  |> fields.and(duration_field(), fn(m: StopMeasurements(extra)) { m.duration })
  |> fields.and(monotonic_time_field(), fn(m) { m.monotonic_time })
  |> fields.and(extra, fn(m) { m.extra })
  |> fields.build
}

fn exception_measurement_fields() -> fields.Fields(ExceptionMeasurements) {
  fields.record({
    use duration <- fields.parameter
    use monotonic_time <- fields.parameter
    ExceptionMeasurements(duration:, monotonic_time:)
  })
  |> fields.and(duration_field(), fn(m: ExceptionMeasurements) { m.duration })
  |> fields.and(monotonic_time_field(), fn(m) { m.monotonic_time })
  |> fields.build
}

fn start_metadata_fields(
  metadata: fields.Fields(metadata),
) -> fields.Fields(StartMetadata(metadata)) {
  fields.record({
    use metadata <- fields.parameter
    use context <- fields.parameter
    StartMetadata(metadata:, context:)
  })
  |> fields.and(metadata, fn(m: StartMetadata(metadata)) { m.metadata })
  |> fields.and(span_context_field(), fn(m) { m.context })
  |> fields.build
}

fn stop_metadata_fields(
  metadata: fields.Fields(metadata),
) -> fields.Fields(StopMetadata(metadata)) {
  fields.record({
    use metadata <- fields.parameter
    use context <- fields.parameter
    StopMetadata(metadata:, context:)
  })
  |> fields.and(metadata, fn(m: StopMetadata(metadata)) { m.metadata })
  |> fields.and(span_context_field(), fn(m) { m.context })
  |> fields.build
}

fn exception_metadata_fields(
  metadata: fields.Fields(metadata),
) -> fields.Fields(ExceptionMetadata(metadata)) {
  fields.record({
    use metadata <- fields.parameter
    use context <- fields.parameter
    use kind <- fields.parameter
    use reason <- fields.parameter
    use stacktrace <- fields.parameter
    ExceptionMetadata(metadata:, context:, kind:, reason:, stacktrace:)
  })
  |> fields.and(metadata, fn(m: ExceptionMetadata(metadata)) { m.metadata })
  |> fields.and(span_context_field(), fn(m) { m.context })
  |> fields.and(kind_field(), fn(m) { m.kind })
  |> fields.and(
    fields.field(
      "reason",
      fn(reason) {
        let ExceptionReason(value) = reason
        value
      },
      decode.dynamic |> decode.map(ExceptionReason),
    ),
    fn(m) { m.reason },
  )
  |> fields.and(
    fields.field(
      "stacktrace",
      fn(stacktrace) {
        let ExceptionStacktrace(value) = stacktrace
        value
      },
      decode.dynamic |> decode.map(ExceptionStacktrace),
    ),
    fn(m) { m.stacktrace },
  )
  |> fields.build
}

fn kind_field() -> fields.Fields(ExceptionKind) {
  fields.field(
    "kind",
    fn(kind) {
      atom.to_dynamic(
        atom.create(case kind {
          ExceptionError -> "error"
          ExceptionExit -> "exit"
          ExceptionThrow -> "throw"
        }),
      )
    },
    atom.decoder()
      |> decode.then(fn(kind) {
        case atom.to_string(kind) {
          "error" -> decode.success(ExceptionError)
          "exit" -> decode.success(ExceptionExit)
          "throw" -> decode.success(ExceptionThrow)
          _ -> decode.failure(ExceptionError, "error, exit or throw")
        }
      }),
  )
}

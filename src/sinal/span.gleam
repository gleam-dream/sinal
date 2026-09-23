import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom.{type Atom}
import gleam/list
import sinal
import sinal/fields
import sinal/internal/ffi

pub opaque type EventPrefix {
  EventPrefix(prefix: List(Atom))
}

pub type PrefixError {
  EmptyPrefix
}

/// Constructs a span event prefix from trusted atoms, rejecting empty prefixes.
pub fn event_prefix(prefix: List(Atom)) -> Result(EventPrefix, PrefixError) {
  case prefix {
    [] -> Error(EmptyPrefix)
    _ -> Ok(EventPrefix(prefix))
  }
}

/// Returns the logical prefix strings derived from the native prefix atoms.
pub fn prefix_name(prefix: EventPrefix) -> List(String) {
  list.map(prefix.prefix, atom.to_string)
}

/// Returns the native prefix atom list.
pub fn prefix_native_name(prefix: EventPrefix) -> List(Atom) {
  prefix.prefix
}

pub opaque type SystemTime {
  SystemTime(Int)
}

pub opaque type MonotonicTime {
  MonotonicTime(Int)
}

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

pub opaque type SpanContext {
  SpanContext(Dynamic)
}

pub opaque type ExceptionReason {
  ExceptionReason(Dynamic)
}

pub opaque type ExceptionStacktrace {
  ExceptionStacktrace(Dynamic)
}

pub type ExceptionKind {
  ExceptionError
  ExceptionExit
  ExceptionThrow
}

pub fn system_time_to_dynamic(time: SystemTime) -> Dynamic {
  let SystemTime(value) = time
  ffi.to_dynamic(value)
}

pub fn monotonic_time_to_dynamic(time: MonotonicTime) -> Dynamic {
  let MonotonicTime(value) = time
  ffi.to_dynamic(value)
}

pub fn duration_to_dynamic(duration: NativeDuration) -> Dynamic {
  let NativeDuration(value) = duration
  ffi.to_dynamic(value)
}

@external(erlang, "sinal_ffi", "convert_native_time")
fn convert_native_time(value: Int, unit: TimeUnit) -> Int

/// Converts a native span duration to the selected unit.
pub fn duration_in(duration: NativeDuration, unit: TimeUnit) -> Int {
  let NativeDuration(value) = duration
  convert_native_time(value, unit)
}

/// Converts a native system timestamp to the selected unit.
pub fn system_time_in(time: SystemTime, unit: TimeUnit) -> Int {
  let SystemTime(value) = time
  convert_native_time(value, unit)
}

/// Converts a native monotonic timestamp to the selected unit.
pub fn monotonic_time_in(time: MonotonicTime, unit: TimeUnit) -> Int {
  let MonotonicTime(value) = time
  convert_native_time(value, unit)
}

pub fn span_context_to_dynamic(context: SpanContext) -> Dynamic {
  let SpanContext(dyn) = context
  dyn
}

pub fn exception_reason_to_dynamic(reason: ExceptionReason) -> Dynamic {
  let ExceptionReason(dyn) = reason
  dyn
}

pub fn exception_stacktrace_to_dynamic(
  stacktrace: ExceptionStacktrace,
) -> Dynamic {
  let ExceptionStacktrace(dyn) = stacktrace
  dyn
}

pub type StartMeasurements {
  StartMeasurements(system_time: SystemTime, monotonic_time: MonotonicTime)
}

pub type StopMeasurements(extra) {
  StopMeasurements(
    duration: NativeDuration,
    monotonic_time: MonotonicTime,
    extra: extra,
  )
}

pub type ExceptionMeasurements {
  ExceptionMeasurements(duration: NativeDuration, monotonic_time: MonotonicTime)
}

pub type StartMetadata(metadata) {
  StartMetadata(metadata: metadata, context: SpanContext)
}

pub type StopMetadata(metadata) {
  StopMetadata(metadata: metadata, context: SpanContext)
}

pub type ExceptionMetadata(metadata) {
  ExceptionMetadata(
    metadata: metadata,
    context: SpanContext,
    kind: ExceptionKind,
    reason: ExceptionReason,
    stacktrace: ExceptionStacktrace,
  )
}

pub opaque type Span(start_metadata, extra_measurements, stop_metadata) {
  Span(
    prefix: EventPrefix,
    start_metadata: fields.Fields(start_metadata),
    extra_measurements: fields.Fields(extra_measurements),
    stop_metadata: fields.Fields(stop_metadata),
  )
}

pub type SpanDefinitionError {
  ReservedMeasurementField(String)
  ReservedMetadataField(String)
}

/// Defines a typed span descriptor, rejecting reserved fields owned by the span protocol.
pub fn define_span(
  prefix: EventPrefix,
  start_metadata: fields.Fields(start_metadata),
  extra_measurements: fields.Fields(extra_measurements),
  stop_metadata: fields.Fields(stop_metadata),
) -> Result(
  Span(start_metadata, extra_measurements, stop_metadata),
  SpanDefinitionError,
) {
  case
    check_reserved(
      extra_measurements,
      ["duration", "monotonic_time"],
      ReservedMeasurementField,
    ),
    check_reserved(
      start_metadata,
      ["telemetry_span_context", "kind", "reason", "stacktrace"],
      ReservedMetadataField,
    ),
    check_reserved(
      stop_metadata,
      ["telemetry_span_context"],
      ReservedMetadataField,
    )
  {
    Ok(Nil), Ok(Nil), Ok(Nil) ->
      Ok(Span(prefix, start_metadata, extra_measurements, stop_metadata))
    Error(err), _, _ -> Error(err)
    _, Error(err), _ -> Error(err)
    _, _, Error(err) -> Error(err)
  }
}

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

/// Derives typed start, stop, and exception event descriptors for the span.
pub fn events(
  span: Span(start_metadata, extra_measurements, stop_metadata),
) -> SpanEvents(start_metadata, extra_measurements, stop_metadata) {
  let prefix = span.prefix.prefix
  let assert Ok(start_ev) =
    sinal.event(
      list.append(prefix, [atom.create("start")]),
      start_measurement_fields(),
      start_metadata_fields(span.start_metadata),
    )
  let assert Ok(stop_ev) =
    sinal.event(
      list.append(prefix, [atom.create("stop")]),
      stop_measurement_fields(span.extra_measurements),
      stop_metadata_fields(span.stop_metadata),
    )
  let assert Ok(exception_ev) =
    sinal.event(
      list.append(prefix, [atom.create("exception")]),
      exception_measurement_fields(),
      exception_metadata_fields(span.start_metadata),
    )
  SpanEvents(start: start_ev, stop: stop_ev, exception: exception_ev)
}

pub type Completion(result, extra_measurements, stop_metadata) {
  Completion(
    result: result,
    measurements: extra_measurements,
    metadata: stop_metadata,
  )
}

pub type CompletionEncodeError {
  ExtraMeasurementsEncodingFailed(fields.FieldEncodeError)
  StopMetadataEncodingFailed(fields.FieldEncodeError)
}

/// Completed work is retained when stop instrumentation cannot be encoded.
pub type SpanOutcome(a) {
  SpanCompleted(a)
  StartEncodingFailed(fields.FieldEncodeError)
  CompletionEncodingFailed(result: a, error: CompletionEncodeError)
}

type EncodedCompletion(a) {
  EncodedCompletion(a, Dynamic, Dynamic)
  UnencodedCompletion(a, CompletionEncodeError)
}

@external(erlang, "sinal_ffi", "telemetry_span_outcome")
fn telemetry_span_outcome(
  prefix: List(Atom),
  start_metadata: Dynamic,
  work: fn() -> EncodedCompletion(a),
) -> SpanOutcome(a)

/// Executes a span without panicking for metadata encoding failures. Start
/// failure skips work and emits no event. Completion failure retains the work
/// result; native telemetry emits an exception event with a structured
/// `sinal_completion_encoding_failed` reason and no stop event. The reason
/// carries a private per-call reference and the encoding error. The completed
/// business result stays private. Catchable exceptions raised by work follow native telemetry's
/// exception event and exact re-raise behavior.
pub fn run_span_result(
  span: Span(start_metadata, extra_measurements, stop_metadata),
  start_metadata: start_metadata,
  work: fn() -> Completion(a, extra_measurements, stop_metadata),
) -> SpanOutcome(a) {
  case fields.encode(span.start_metadata, start_metadata) {
    Error(error) -> StartEncodingFailed(error)
    Ok(raw_start_metadata) ->
      telemetry_span_outcome(span.prefix.prefix, raw_start_metadata, fn() {
        let Completion(result, extra, stop) = work()
        case fields.encode(span.extra_measurements, extra) {
          Error(error) ->
            UnencodedCompletion(result, ExtraMeasurementsEncodingFailed(error))
          Ok(raw_extra) ->
            case fields.encode(span.stop_metadata, stop) {
              Error(error) ->
                UnencodedCompletion(result, StopMetadataEncodingFailed(error))
              Ok(raw_stop) -> EncodedCompletion(result, raw_extra, raw_stop)
            }
        }
      })
  }
}

/// Executes work inside a native telemetry span, emitting start and either stop or exception events.
pub fn run_span(
  span: Span(start_metadata, extra_measurements, stop_metadata),
  start_metadata: start_metadata,
  work: fn() -> Completion(a, extra_measurements, stop_metadata),
) -> a {
  let raw_start_metadata = case
    fields.encode(span.start_metadata, start_metadata)
  {
    Ok(map) -> map
    Error(fields.FieldEncodeError(msg)) ->
      panic as { "Failed to encode span start metadata: " <> msg }
  }

  ffi.telemetry_span(span.prefix.prefix, raw_start_metadata, fn() {
    let Completion(result, extra_meas, stop_meta) = work()
    let raw_extra_meas = case
      fields.encode(span.extra_measurements, extra_meas)
    {
      Ok(map) -> map
      Error(fields.FieldEncodeError(msg)) ->
        panic as { "Failed to encode span extra measurements: " <> msg }
    }
    let raw_stop_meta = case fields.encode(span.stop_metadata, stop_meta) {
      Ok(map) -> map
      Error(fields.FieldEncodeError(msg)) ->
        panic as { "Failed to encode span stop metadata: " <> msg }
    }
    #(result, raw_extra_meas, raw_stop_meta)
  })
}

fn start_measurement_fields() -> fields.Fields(StartMeasurements) {
  let sys_key = atom.create("system_time")
  let mono_key = atom.create("monotonic_time")
  let sys_field =
    fields.field(
      sys_key,
      fn(time) {
        let SystemTime(value) = time
        Ok(ffi.to_dynamic(value))
      },
      fn(dyn) {
        case decode.run(dyn, decode.int) {
          Ok(value) -> Ok(SystemTime(value))
          Error(_) ->
            Error(fields.FieldDecodeError(
              "Expected a native integer system_time",
            ))
        }
      },
    )
  let mono_field =
    fields.field(
      mono_key,
      fn(time) {
        let MonotonicTime(value) = time
        Ok(ffi.to_dynamic(value))
      },
      fn(dyn) {
        case decode.run(dyn, decode.int) {
          Ok(value) -> Ok(MonotonicTime(value))
          Error(_) ->
            Error(fields.FieldDecodeError(
              "Expected a native integer monotonic_time",
            ))
        }
      },
    )
  let assert Ok(p) = fields.pair(sys_field, mono_field)
  fields.imap(
    p,
    fn(pair) { StartMeasurements(pair.0, pair.1) },
    fn(m: StartMeasurements) { #(m.system_time, m.monotonic_time) },
  )
}

fn stop_measurement_fields(
  extra: fields.Fields(extra),
) -> fields.Fields(StopMeasurements(extra)) {
  let dur_key = atom.create("duration")
  let mono_key = atom.create("monotonic_time")
  let dur_field =
    fields.field(
      dur_key,
      fn(dur) {
        let NativeDuration(value) = dur
        Ok(ffi.to_dynamic(value))
      },
      fn(dyn) {
        case decode.run(dyn, decode.int) {
          Ok(value) -> Ok(NativeDuration(value))
          Error(_) ->
            Error(fields.FieldDecodeError("Expected a native integer duration"))
        }
      },
    )
  let mono_field =
    fields.field(
      mono_key,
      fn(time) {
        let MonotonicTime(value) = time
        Ok(ffi.to_dynamic(value))
      },
      fn(dyn) {
        case decode.run(dyn, decode.int) {
          Ok(value) -> Ok(MonotonicTime(value))
          Error(_) ->
            Error(fields.FieldDecodeError(
              "Expected a native integer monotonic_time",
            ))
        }
      },
    )
  let assert Ok(timing) = fields.pair(dur_field, mono_field)
  let assert Ok(all) = fields.pair(timing, extra)
  fields.imap(
    all,
    fn(pair) {
      let #(#(dur, mono), extra_meas) = pair
      StopMeasurements(dur, mono, extra_meas)
    },
    fn(m: StopMeasurements(extra)) {
      #(#(m.duration, m.monotonic_time), m.extra)
    },
  )
}

fn exception_measurement_fields() -> fields.Fields(ExceptionMeasurements) {
  let dur_key = atom.create("duration")
  let mono_key = atom.create("monotonic_time")
  let dur_field =
    fields.field(
      dur_key,
      fn(dur) {
        let NativeDuration(value) = dur
        Ok(ffi.to_dynamic(value))
      },
      fn(dyn) {
        case decode.run(dyn, decode.int) {
          Ok(value) -> Ok(NativeDuration(value))
          Error(_) ->
            Error(fields.FieldDecodeError("Expected a native integer duration"))
        }
      },
    )
  let mono_field =
    fields.field(
      mono_key,
      fn(time) {
        let MonotonicTime(value) = time
        Ok(ffi.to_dynamic(value))
      },
      fn(dyn) {
        case decode.run(dyn, decode.int) {
          Ok(value) -> Ok(MonotonicTime(value))
          Error(_) ->
            Error(fields.FieldDecodeError(
              "Expected a native integer monotonic_time",
            ))
        }
      },
    )
  let assert Ok(timing) = fields.pair(dur_field, mono_field)
  fields.imap(
    timing,
    fn(pair) { ExceptionMeasurements(pair.0, pair.1) },
    fn(m: ExceptionMeasurements) { #(m.duration, m.monotonic_time) },
  )
}

fn span_context_field() -> fields.Fields(SpanContext) {
  let ctx_key = atom.create("telemetry_span_context")
  fields.field(
    ctx_key,
    fn(c) {
      let SpanContext(dyn) = c
      Ok(dyn)
    },
    fn(dyn) { Ok(SpanContext(dyn)) },
  )
}

fn start_metadata_fields(
  metadata: fields.Fields(meta),
) -> fields.Fields(StartMetadata(meta)) {
  let ctx = span_context_field()
  let assert Ok(p) = fields.pair(metadata, ctx)
  fields.imap(
    p,
    fn(pair) { StartMetadata(pair.0, pair.1) },
    fn(m: StartMetadata(meta)) { #(m.metadata, m.context) },
  )
}

fn stop_metadata_fields(
  metadata: fields.Fields(meta),
) -> fields.Fields(StopMetadata(meta)) {
  let ctx = span_context_field()
  let assert Ok(p) = fields.pair(metadata, ctx)
  fields.imap(
    p,
    fn(pair) { StopMetadata(pair.0, pair.1) },
    fn(m: StopMetadata(meta)) { #(m.metadata, m.context) },
  )
}

fn exception_metadata_fields(
  metadata: fields.Fields(meta),
) -> fields.Fields(ExceptionMetadata(meta)) {
  let ctx = span_context_field()
  let kind_key = atom.create("kind")
  let reason_key = atom.create("reason")
  let stack_key = atom.create("stacktrace")

  let kind_field =
    fields.field(
      kind_key,
      fn(kind) {
        case kind {
          ExceptionError -> Ok(ffi.to_dynamic(atom.create("error")))
          ExceptionExit -> Ok(ffi.to_dynamic(atom.create("exit")))
          ExceptionThrow -> Ok(ffi.to_dynamic(atom.create("throw")))
        }
      },
      fn(dyn) {
        case decode.run(dyn, atom.decoder()) {
          Ok(a) ->
            case atom.to_string(a) {
              "error" -> Ok(ExceptionError)
              "exit" -> Ok(ExceptionExit)
              "throw" -> Ok(ExceptionThrow)
              _ ->
                Error(fields.FieldDecodeError(
                  "Expected exception kind atom: error, exit, or throw",
                ))
            }
          Error(_) ->
            Error(fields.FieldDecodeError(
              "Expected exception kind atom: error, exit, or throw",
            ))
        }
      },
    )

  let reason_field =
    fields.field(
      reason_key,
      fn(r) {
        let ExceptionReason(dyn) = r
        Ok(dyn)
      },
      fn(dyn) { Ok(ExceptionReason(dyn)) },
    )

  let stack_field =
    fields.field(
      stack_key,
      fn(s) {
        let ExceptionStacktrace(dyn) = s
        Ok(dyn)
      },
      fn(dyn) { Ok(ExceptionStacktrace(dyn)) },
    )

  let assert Ok(with_ctx) = fields.pair(metadata, ctx)
  let assert Ok(with_kind) = fields.pair(with_ctx, kind_field)
  let assert Ok(with_reason) = fields.pair(with_kind, reason_field)
  let assert Ok(all) = fields.pair(with_reason, stack_field)

  fields.imap(
    all,
    fn(tuple) {
      let #(#(#(#(meta, c), k), r), s) = tuple
      ExceptionMetadata(meta, c, k, r, s)
    },
    fn(m: ExceptionMetadata(meta)) {
      #(#(#(#(m.metadata, m.context), m.kind), m.reason), m.stacktrace)
    },
  )
}

fn check_reserved(
  f: fields.Fields(a),
  reserved: List(String),
  make_error: fn(String) -> SpanDefinitionError,
) -> Result(Nil, SpanDefinitionError) {
  case first_overlap(fields.declared_keys(f), reserved) {
    Error(Nil) -> Ok(Nil)
    Ok(name) -> Error(make_error(name))
  }
}

fn first_overlap(
  names: List(String),
  reserved: List(String),
) -> Result(String, Nil) {
  case names {
    [] -> Error(Nil)
    [name, ..rest] ->
      case list.contains(reserved, name) {
        True -> Ok(name)
        False -> first_overlap(rest, reserved)
      }
  }
}

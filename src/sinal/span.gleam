import gleam/erlang/atom.{type Atom}
import gleam/list
import sinal
import sinal/fields

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

/// Convenience constructor for trusted span prefixes.
pub fn trusted_prefix(prefix: List(Atom)) -> Result(EventPrefix, PrefixError) {
  event_prefix(prefix)
}

/// Returns the logical prefix strings derived from the native prefix atoms.
pub fn prefix_name(prefix: EventPrefix) -> List(String) {
  list.map(prefix.prefix, atom.to_string)
}

/// Returns the native prefix atom list.
pub fn prefix_native_name(prefix: EventPrefix) -> List(Atom) {
  prefix.prefix
}

pub type SystemTime

pub type MonotonicTime

pub type NativeDuration

pub type SpanContext

pub type ExceptionReason

pub type ExceptionStacktrace

pub type ExceptionKind {
  ExceptionError
  ExceptionExit
  ExceptionThrow
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

pub fn events(
  _span: Span(start_metadata, extra_measurements, stop_metadata),
) -> SpanEvents(start_metadata, extra_measurements, stop_metadata) {
  todo as "span event descriptor derivation is not yet implemented"
}

pub type Completion(result, extra_measurements, stop_metadata) {
  Completion(
    result: result,
    measurements: extra_measurements,
    metadata: stop_metadata,
  )
}

pub fn run_span(
  _span: Span(start_metadata, extra_measurements, stop_metadata),
  _start_metadata: start_metadata,
  _work: fn() -> Completion(a, extra_measurements, stop_metadata),
) -> a {
  todo as "native telemetry run_span is not yet implemented"
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

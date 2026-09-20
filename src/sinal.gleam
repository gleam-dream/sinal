import gleam/erlang/atom.{type Atom}
import gleam/list
import sinal/exception.{type BeamException}
import sinal/fields.{type FieldEncodeError, type FieldError, type Fields}

/// Package version reporting for compatibility checks and smoke testing.
pub fn version() -> String {
  "0.1.0"
}

/// A strongly-typed event descriptor retaining native atom identity
/// and typed measurement and metadata field specifications.
pub opaque type Event(measurements, metadata) {
  Event(
    name: List(Atom),
    measurements: Fields(measurements),
    metadata: Fields(metadata),
  )
}

pub type EventError {
  EmptyEventName
}

/// Constructs a typed event descriptor from trusted native atoms, deriving
/// the logical name safely from the atoms and rejecting empty names.
pub fn event(
  name: List(Atom),
  measurements: Fields(m),
  metadata: Fields(d),
) -> Result(Event(m, d), EventError) {
  case name {
    [] -> Error(EmptyEventName)
    _ -> Ok(Event(name, measurements, metadata))
  }
}

/// Convenience constructor for trusted native event descriptors.
pub fn trusted_event(
  name: List(Atom),
  measurements: Fields(m),
  metadata: Fields(d),
) -> Result(Event(m, d), EventError) {
  event(name, measurements, metadata)
}

/// Exposes the logical name derived from the native atom list.
pub fn event_name(event: Event(m, d)) -> List(String) {
  list.map(event.name, atom.to_string)
}

/// Exposes the native atom list binding.
pub fn event_native_name(event: Event(m, d)) -> List(Atom) {
  event.name
}

pub opaque type HandlerId {
  PublicHandlerId(String)
  ScopedHandlerId(Int)
}

pub type IdentityError {
  EmptyHandlerId
}

/// Creates a public handler identifier, rejecting empty names.
pub fn handler_id(name: String) -> Result(HandlerId, IdentityError) {
  case name {
    "" -> Error(EmptyHandlerId)
    _ -> Ok(PublicHandlerId(name))
  }
}

@external(erlang, "erlang", "unique_integer")
fn fresh_scoped_handler_number() -> Int

pub opaque type Handler(m, d, e) {
  Handler(run: fn(Event(m, d), m, d) -> Result(Nil, e))
}

/// Constructs a typed handler receiving the selected descriptor and decoded values.
pub fn handler(
  run: fn(Event(m, d), m, d) -> Result(Nil, e),
) -> Handler(m, d, e) {
  Handler(run)
}

pub opaque type Attachment {
  Attachment(detach_fn: fn() -> Result(Nil, DetachError))
}

pub type AttachError {
  AlreadyExists
  DuplicateEventName(List(String))
  BackendNotAvailable
}

pub type DetachError {
  NotAttached
  DetachBackendNotAvailable
}

pub type EmitError {
  EncodingFailed(FieldEncodeError)
  BackendFailed(String)
}

pub type HandlerFailure(e) {
  MalformedMeasurements(FieldError)
  MalformedMetadata(FieldError)
  HandlerReturned(e)
}

pub type ScopeCleanupFailure {
  DetachReturnedError(DetachError)
  DetachRaisedException(BeamException)
}

pub type ScopedCompletion(a) {
  ScopedCompletion(
    work_result: a,
    cleanup_result: Result(Nil, ScopeCleanupFailure),
  )
}

/// Detaches an installed handler using its originating detach callback.
pub fn detach(attachment: Attachment) -> Result(Nil, DetachError) {
  let Attachment(detach_fn) = attachment
  detach_fn()
}

/// Validates that a nonempty set of event descriptors contains no duplicate native names.
pub fn validate_event_names(
  first: Event(m, d),
  rest: List(Event(m, d)),
) -> Result(Nil, AttachError) {
  validate_rest_names(rest, [first.name])
}

fn validate_rest_names(
  rest: List(Event(m, d)),
  seen: List(List(Atom)),
) -> Result(Nil, AttachError) {
  case rest {
    [] -> Ok(Nil)
    [ev, ..tail] ->
      case list.contains(seen, ev.name) {
        True -> Error(DuplicateEventName(list.map(ev.name, atom.to_string)))
        False -> validate_rest_names(tail, [ev.name, ..seen])
      }
  }
}

/// Emits an event synchronously to native BEAM telemetry.
pub fn emit(
  _event: Event(m, d),
  _measurements: m,
  _metadata: d,
) -> Result(Nil, EmitError) {
  todo as "native telemetry emit is not yet implemented"
}

/// Attaches a typed handler to a single event descriptor.
pub fn attach(
  _id: HandlerId,
  _event: Event(m, d),
  _handler: Handler(m, d, e),
  _on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
) -> Result(Attachment, AttachError) {
  todo as "native telemetry attach is not yet implemented"
}

/// Attaches a typed handler to multiple same-shaped event descriptors.
pub fn attach_many(
  _id: HandlerId,
  first: Event(m, d),
  rest: List(Event(m, d)),
  _handler: Handler(m, d, e),
  _on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
) -> Result(Attachment, AttachError) {
  case validate_event_names(first, rest) {
    Error(err) -> Error(err)
    Ok(Nil) -> todo as "native telemetry attach_many is not yet implemented"
  }
}

/// Executes work with temporary attachments, guaranteeing cleanup attempt and
/// preserving original return values separately from cleanup outcome.
pub fn with_attachments(
  first: Event(m, d),
  rest: List(Event(m, d)),
  _handler: Handler(m, d, e),
  _on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
  _on_exception_cleanup_failure: fn(ScopeCleanupFailure) -> Nil,
  _run: fn() -> a,
) -> Result(ScopedCompletion(a), AttachError) {
  case validate_event_names(first, rest) {
    Error(err) -> Error(err)
    Ok(Nil) -> {
      let _scoped_id = ScopedHandlerId(fresh_scoped_handler_number())
      todo as "scoped attachment lifetime is not yet implemented"
    }
  }
}

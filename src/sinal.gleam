import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import sinal/exception.{type BeamException}
import sinal/fields.{type FieldEncodeError, type FieldError, type Fields}
import sinal/internal/ffi

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
  event: Event(m, d),
  measurements: m,
  metadata: d,
) -> Result(Nil, EmitError) {
  case fields.encode(event.measurements, measurements) {
    Error(err) -> Error(EncodingFailed(err))
    Ok(raw_measurements) ->
      case fields.encode(event.metadata, metadata) {
        Error(err) -> Error(EncodingFailed(err))
        Ok(raw_metadata) -> {
          ffi.telemetry_execute(event.name, raw_measurements, raw_metadata)
          Ok(Nil)
        }
      }
  }
}

/// Attaches a typed handler to a single event descriptor.
pub fn attach(
  id: HandlerId,
  event: Event(m, d),
  handler: Handler(m, d, e),
  on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
) -> Result(Attachment, AttachError) {
  attach_many(id, event, [], handler, on_failure)
}

/// Attaches a typed handler to multiple same-shaped event descriptors.
pub fn attach_many(
  id: HandlerId,
  first: Event(m, d),
  rest: List(Event(m, d)),
  handler: Handler(m, d, e),
  on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
) -> Result(Attachment, AttachError) {
  case validate_event_names(first, rest) {
    Error(err) -> Error(err)
    Ok(Nil) -> {
      let descriptors = [first, ..rest]
      let event_names = list.map(descriptors, fn(ev) { ev.name })
      let callback = fn(event_name, raw_measurements, raw_metadata, _config) {
        dispatch(
          event_name,
          raw_measurements,
          raw_metadata,
          descriptors,
          handler,
          on_failure,
        )
      }
      let raw_id = ffi.to_dynamic(id)
      case
        ffi.telemetry_attach_many(
          raw_id,
          event_names,
          callback,
          ffi.to_dynamic(Nil),
        )
      {
        Ok(Nil) -> {
          let detach_fn = fn() {
            case ffi.telemetry_detach(raw_id) {
              Ok(Nil) -> Ok(Nil)
              Error(ffi.NativeNotFound) -> Error(NotAttached)
              Error(ffi.NativeDetachOther(_)) ->
                Error(DetachBackendNotAvailable)
            }
          }
          Ok(Attachment(detach_fn))
        }
        Error(ffi.NativeAlreadyExists) -> Error(AlreadyExists)
        Error(ffi.NativeAttachOther(_)) -> Error(BackendNotAvailable)
      }
    }
  }
}

fn dispatch(
  event_name: List(Atom),
  raw_measurements: Dynamic,
  raw_metadata: Dynamic,
  descriptors: List(Event(m, d)),
  handler: Handler(m, d, e),
  on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
) -> Nil {
  case list.find(descriptors, fn(ev) { ev.name == event_name }) {
    Error(Nil) -> ffi.raise_callback_failure("unrecognized_event_descriptor")
    Ok(descriptor) ->
      case fields.decode(descriptor.measurements, raw_measurements) {
        Error(field_err) -> {
          on_failure(descriptor, MalformedMeasurements(field_err))
          ffi.raise_callback_failure("malformed_measurements")
        }
        Ok(measurements) ->
          case fields.decode(descriptor.metadata, raw_metadata) {
            Error(field_err) -> {
              on_failure(descriptor, MalformedMetadata(field_err))
              ffi.raise_callback_failure("malformed_metadata")
            }
            Ok(metadata) -> {
              let Handler(run) = handler
              case run(descriptor, measurements, metadata) {
                Ok(Nil) -> Nil
                Error(handler_err) -> {
                  on_failure(descriptor, HandlerReturned(handler_err))
                  ffi.raise_callback_failure("handler_returned_error")
                }
              }
            }
          }
      }
  }
}

/// Executes work with temporary attachments, guaranteeing cleanup attempt and
/// preserving original return values separately from cleanup outcome.
@external(erlang, "sinal_scope_ffi", "with_scope")
fn ffi_with_scope(
  work: fn() -> a,
  cleanup: fn() -> Result(Nil, DetachError),
  on_cleanup_failure: fn(ScopeCleanupFailure) -> Nil,
) -> ScopedCompletion(a)

/// Executes work with temporary attachments, guaranteeing cleanup attempt and
/// preserving original return values separately from cleanup outcome.
pub fn with_attachments(
  first: Event(m, d),
  rest: List(Event(m, d)),
  handler: Handler(m, d, e),
  on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
  on_exception_cleanup_failure: fn(ScopeCleanupFailure) -> Nil,
  run: fn() -> a,
) -> Result(ScopedCompletion(a), AttachError) {
  case validate_event_names(first, rest) {
    Error(err) -> Error(err)
    Ok(Nil) -> {
      let scoped_id = ScopedHandlerId(fresh_scoped_handler_number())
      case attach_many(scoped_id, first, rest, handler, on_failure) {
        Error(err) -> Error(err)
        Ok(attachment) -> {
          let cleanup = fn() { detach(attachment) }
          let completion =
            ffi_with_scope(run, cleanup, on_exception_cleanup_failure)
          Ok(completion)
        }
      }
    }
  }
}

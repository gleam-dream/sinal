import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/list
import sinal/exception.{type BeamException}
import sinal/fields.{type FieldEncodeError, type FieldError, type Fields}
import sinal/internal/ffi

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

/// Canonical constructor for a typed event descriptor from trusted native atoms, deriving
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

/// A pure description of one independently registered typed observer. The
/// event and callbacks are bound before the runner erases their type parameters.
pub opaque type Subscription {
  Subscription(acquire: fn() -> Result(Attachment, AttachError))
}

/// A pure plan for a heterogeneous scope. The default exception-cleanup
/// reporter is silent; normal cleanup failures remain in the result.
pub opaque type SubscriptionPlan {
  SubscriptionPlan(
    entries: List(Subscription),
    exception_cleanup_reporter: fn(SubscriptionCleanupFailure) -> Nil,
  )
}

pub type SubscriptionCleanupFailure {
  SubscriptionCleanupFailure(index: Int, failure: ScopeCleanupFailure)
}

pub type SubscriptionScopeError {
  SubscriptionAttachFailed(
    index: Int,
    error: AttachError,
    rollback_failures: List(SubscriptionCleanupFailure),
  )
}

pub type SubscriptionCompletion(a) {
  SubscriptionCompletion(
    work_result: a,
    cleanup_failures: List(SubscriptionCleanupFailure),
  )
}

type Acquisition(a) {
  Acquired(a)
  AcquisitionRaised(BeamException)
}

@external(erlang, "sinal_scope_ffi", "acquire_subscription")
fn ffi_acquire_subscription(
  acquire: fn() -> Result(Attachment, AttachError),
) -> Acquisition(Result(Attachment, AttachError))

@external(erlang, "sinal_scope_ffi", "cleanup_and_reraise")
fn cleanup_and_reraise(
  cleanups: List(#(Int, fn() -> Result(Nil, DetachError))),
  on_cleanup_failure: fn(SubscriptionCleanupFailure) -> Nil,
  exception: BeamException,
) -> a

/// Binds a typed event and fallible handler for later scoped acquisition.
/// The explicit ID permits application-owned handler identity.
pub fn handler_subscription(
  id: HandlerId,
  event: Event(m, d),
  handler: fn(Event(m, d), m, d) -> Result(Nil, e),
  on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
) -> Subscription {
  Subscription(fn() { attach(id, event, handler, on_failure) })
}

/// Binds an infallible typed observer for later scoped acquisition.
pub fn subscription(event: Event(m, d), run: fn(m, d) -> Nil) -> Subscription {
  Subscription(fn() {
    observe(ScopedHandlerId(fresh_scoped_handler_number()), event, run)
  })
}

/// Builds a scope with no exception-cleanup reporting side effect.
pub fn subscriptions(entries: List(Subscription)) -> SubscriptionPlan {
  SubscriptionPlan(entries, fn(_) { Nil })
}

/// Reports cleanup failures that occur while an original exception is raised.
pub fn with_exception_cleanup_reporter(
  plan: SubscriptionPlan,
  reporter: fn(SubscriptionCleanupFailure) -> Nil,
) -> SubscriptionPlan {
  SubscriptionPlan(..plan, exception_cleanup_reporter: reporter)
}

/// Detaches an installed handler using its originating detach callback.
pub fn detach(attachment: Attachment) -> Result(Nil, DetachError) {
  let Attachment(detach_fn) = attachment
  detach_fn()
}

/// Validates that a nonempty set of event descriptors contains no duplicate native names.
fn validate_event_names(
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
  handler: fn(Event(m, d), m, d) -> Result(Nil, e),
  on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
) -> Result(Attachment, AttachError) {
  attach_many(id, event, [], handler, on_failure)
}

/// Attaches an infallible observer to one event using native failure isolation.
/// The callback runs synchronously in the emitting process. Malformed native
/// maps still remove this registration and emit telemetry's handler failure event.
/// Retain the returned attachment and call `detach` when observation is complete.
pub fn observe(
  id: HandlerId,
  event: Event(m, d),
  run: fn(m, d) -> Nil,
) -> Result(Attachment, AttachError) {
  attach(
    id,
    event,
    fn(_selected_event, measurements, metadata) {
      run(measurements, metadata)
      Ok(Nil)
    },
    fn(_selected_event, _failure) { Nil },
  )
}

/// Attaches a typed handler to multiple same-shaped event descriptors.
pub fn attach_many(
  id: HandlerId,
  first: Event(m, d),
  rest: List(Event(m, d)),
  handler: fn(Event(m, d), m, d) -> Result(Nil, e),
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
  handler: fn(Event(m, d), m, d) -> Result(Nil, e),
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
              case handler(descriptor, measurements, metadata) {
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

/// Executes work with temporary scoped attachments, guaranteeing one cleanup attempt
/// upon normal return or catchable BEAM exception (error, exit, throw), and preserving
/// original return values separately from cleanup outcomes.
///
/// Limits and operational semantics:
/// - Non-quiescence: Detaching unregisters the handler from subsequent event dispatches,
///   but does not wait for or interrupt callbacks already in flight on other processes.
///   Captured resources should remain valid until independent handler work terminates.
/// - Uncatchable termination: Abrupt process loss, VM termination, or untrappable exits
///   will bypass cleanup. No linear ownership or exactly-once guarantee is promised.
/// - Re-raising: Catchable work exceptions (error, exit, throw) preserve exact class,
///   reason, and stacktrace. Reporter failures do not mask work exceptions.
pub fn with_attachments(
  first: Event(m, d),
  rest: List(Event(m, d)),
  handler: fn(Event(m, d), m, d) -> Result(Nil, e),
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

@external(erlang, "sinal_scope_ffi", "cleanup_subscriptions")
fn cleanup_subscriptions(
  cleanups: List(#(Int, fn() -> Result(Nil, DetachError))),
) -> List(SubscriptionCleanupFailure)

@external(erlang, "sinal_scope_ffi", "with_subscription_scope")
fn ffi_with_subscription_scope(
  work: fn() -> a,
  cleanups: List(#(Int, fn() -> Result(Nil, DetachError))),
  on_cleanup_failure: fn(SubscriptionCleanupFailure) -> Nil,
) -> SubscriptionCompletion(a)

/// Acquires independent subscriptions in order and releases them in reverse
/// order. Acquisition is not atomically visible to concurrent emitters.
/// On acquisition failure, work is skipped and prior registrations are removed.
/// Every cleanup failure retains the subscription's zero-based list index.
/// Catchable work exceptions are re-raised with their original class, reason,
/// and stacktrace after all cleanup attempts.
pub fn with_subscriptions(
  plan: SubscriptionPlan,
  run: fn() -> a,
) -> Result(SubscriptionCompletion(a), SubscriptionScopeError) {
  case
    acquire_subscriptions(plan.entries, 0, [], plan.exception_cleanup_reporter)
  {
    Ok(cleanups) ->
      Ok(ffi_with_subscription_scope(
        run,
        cleanups,
        plan.exception_cleanup_reporter,
      ))
    Error(error) -> Error(error)
  }
}

fn acquire_subscriptions(
  subscriptions: List(Subscription),
  index: Int,
  cleanups: List(#(Int, fn() -> Result(Nil, DetachError))),
  on_exception_cleanup_failure: fn(SubscriptionCleanupFailure) -> Nil,
) -> Result(
  List(#(Int, fn() -> Result(Nil, DetachError))),
  SubscriptionScopeError,
) {
  case subscriptions {
    [] -> Ok(cleanups)
    [Subscription(acquire), ..rest] ->
      case ffi_acquire_subscription(acquire) {
        Acquired(Ok(attachment)) ->
          acquire_subscriptions(
            rest,
            index + 1,
            [#(index, fn() { detach(attachment) }), ..cleanups],
            on_exception_cleanup_failure,
          )
        Acquired(Error(error)) ->
          Error(SubscriptionAttachFailed(
            index,
            error,
            cleanup_subscriptions(cleanups),
          ))
        AcquisitionRaised(exception) ->
          cleanup_and_reraise(cleanups, on_exception_cleanup_failure, exception)
      }
  }
}

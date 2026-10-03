//// Defines typed telemetry events, attaches handlers to them, and emits
//// them through native BEAM `:telemetry`.
////
//// Describe an event once, as an `Event(measurements, metadata)` built
//// from `sinal/fields` codecs, then `emit` it and `observe` it:
////
//// ```gleam
//// import sinal
//// import sinal/fields
////
//// let finished =
////   sinal.event(
////     ["request", "finished"],
////     fields.int("duration_ms"),
////     fields.string("route"),
////   )
//// let attachment =
////   sinal.observe(finished, fn(duration_ms, route) { record(route, duration_ms) })
//// sinal.emit(finished, 42, "/users")
//// let _ = sinal.detach(attachment)
//// ```
////
//// `measurement_fields` and `metadata_fields` return an event's codecs, so
//// a test can pin the native maps that `emit` sends with `fields.encode`,
//// or assert with `fields.check` that no value would be skipped, without
//// attaching a handler.
////
//// ## Delivery
////
//// Handlers run synchronously in the emitting process, unless the
//// application routed a prefix of the event's name to a forwarder with
//// `sinal/forwarder.route`: then `emit` hands the event to that forwarder's
//// process and returns at once. The emitter never crashes. A native map
//// that does not decode skips that one invocation: the handler's failure
//// observer receives the typed `HandlerFailure` (`observe` logs it), and
//// the handler stays attached. A handler that returns an error or crashes
//// is removed, and telemetry emits its standard
//// `[telemetry, handler, failure]` event.
////
//// ## Registration
////
//// `observe` attaches an infallible handler to one event. A `Subscription`
//// describes any registration: `subscription` for one event, `handler`
//// for several same-shaped events with a fallible handler and a typed
//// failure observer, and `with_id` for a stable native handler id. `attach`
//// installs one for the long term; `with_subscriptions` installs a group
//// for the duration of one function call. Sinal gives every handler a
//// fresh id unless `with_id` names one.
////
//// ## Names are atoms
////
//// Each name segment becomes an atom, and the BEAM never frees an atom. A
//// segment must match `[a-z][a-z0-9_]{0,62}` and must be written in source
//// code, never built from input. An invalid segment, an empty name, an
//// empty `with_id` or a repeated event in `handler` is a definition bug:
//// the constructor panics with a message naming it.
////
//// ## The telemetry application
////
//// Native `:telemetry` keeps handlers in a process of the `telemetry` OTP
//// application. `attach`, `observe` and `with_subscriptions` start that
//// application when it is not running, so a script or a release that
//// does not list it still delivers. Without it, `emit` reaches no handler
//// and `detach` returns `Error(Nil)`, because nothing can be attached.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import sinal/fields.{type FieldError, type Fields}
import sinal/internal/emit
import sinal/internal/ffi
import sinal/internal/name as grammar
import sinal/internal/route

/// A typed event: its name and the codecs of its measurements and
/// metadata.
pub opaque type Event(measurements, metadata) {
  Event(
    name: List(Atom),
    measurements: Fields(measurements),
    metadata: Fields(metadata),
  )
}

/// Defines an event. `name` is the native event name, for example
/// `["http_gun", "request", "stop"]`.
///
/// Panics when `name` is empty or a segment breaks the name grammar.
pub fn event(
  name: List(String),
  measurements: Fields(measurements),
  metadata: Fields(metadata),
) -> Event(measurements, metadata) {
  Event(
    name: name_atoms(name, "sinal.event"),
    measurements: measurements,
    metadata: metadata,
  )
}

/// The event's name.
pub fn name(event: Event(m, d)) -> List(String) {
  list.map(event.name, atom.to_string)
}

/// The codec of the event's measurements. A test can encode a value with
/// it to pin the native map that `emit` sends, without attaching a native
/// handler:
///
/// ```gleam
/// fields.encode(sinal.measurement_fields(finished), 42)
/// ```
pub fn measurement_fields(event: Event(m, d)) -> Fields(m) {
  event.measurements
}

/// The codec of the event's metadata, for `fields.encode`, `fields.decode`,
/// `fields.check` and `fields.keys`.
pub fn metadata_fields(event: Event(m, d)) -> Fields(d) {
  event.metadata
}

/// Emits an event. Handlers run in the caller before `emit` returns,
/// unless the application routed a prefix of the event's name with
/// `sinal/forwarder.route`. A routed event is handed to that forwarder and
/// `emit` returns without waiting; when the forwarder is full or not
/// running, the event is dropped and counted in the forwarder's
/// `dropped_event`. Handler failures never reach the caller.
pub fn emit(event: Event(m, d), measurements: m, metadata: d) -> Nil {
  let raw_measurements =
    emit.encode(
      event.measurements,
      measurements,
      caller: "sinal.emit",
      event: fn() { name(event) },
    )
  let raw_metadata =
    emit.encode(event.metadata, metadata, caller: "sinal.emit", event: fn() {
      name(event)
    })
  case route.find(event.name) {
    Ok(send) -> send(event.name, raw_measurements, raw_metadata)
    Error(Nil) ->
      ffi.telemetry_execute(event.name, raw_measurements, raw_metadata)
  }
}

/// A registered handler. Keep it to `detach` the handler.
pub opaque type Attachment {
  Attachment(id: Dynamic)
}

/// Why `attach` refused a subscription. The union is closed.
pub type AttachError {
  /// A handler with this `with_id` id is already attached.
  AlreadyExists(id: String)
}

/// Why a handler did not run. The union is closed.
pub type HandlerFailure(e) {
  MalformedMeasurements(FieldError)
  MalformedMetadata(FieldError)
  HandlerReturned(e)
}

/// Why a scope could not detach one of its handlers. The union is closed.
pub type CleanupFailure {
  /// The handler was no longer attached, for example because telemetry
  /// removed it after it failed.
  AlreadyDetached
  /// Detaching raised; `description` is for logs.
  DetachCrashed(description: String)
}

/// A registration that `attach` or `with_subscriptions` installs. Building
/// one has no effect.
pub opaque type Subscription {
  Subscription(id: Option(String), install: fn(Dynamic) -> Result(Nil, Nil))
}

/// Attaches an infallible handler to one event and returns its attachment.
/// The handler runs in the emitting process (or the forwarder's, for a
/// routed event). A native map that does not decode skips that one
/// invocation and logs a warning; the handler stays attached. A handler
/// crash removes it and emits telemetry's `[telemetry, handler, failure]`
/// event.
pub fn observe(event: Event(m, d), run: fn(m, d) -> Nil) -> Attachment {
  case attach(subscription(event, run)) {
    Ok(attachment) -> attachment
    Error(error) ->
      panic as { "sinal.observe: " <> describe_attach_error(error) }
  }
}

/// Describes an infallible handler of one event. When a native map does
/// not decode, the handler skips that one invocation, stays attached, and
/// logs a warning that names the event and the `HandlerFailure`.
pub fn subscription(event: Event(m, d), run: fn(m, d) -> Nil) -> Subscription {
  handler(
    [event],
    fn(_event, measurements, metadata) {
      run(measurements, metadata)
      Ok(Nil)
    },
    fn(event, failure) {
      ffi.log_warning(
        "sinal.observe: skipped one invocation of event "
        <> string.inspect(name(event))
        <> ": "
        <> describe_handler_failure(failure, fn(_) { "" }),
      )
    },
  )
}

/// Describes one handler of several same-shaped events. `run` receives the
/// event that fired.
///
/// - When a native map does not decode, `on_failure` receives
///   `MalformedMeasurements` or `MalformedMetadata`, `run` is skipped for
///   that one event, and the handler stays attached.
/// - When `run` returns an error, `on_failure` receives `HandlerReturned`,
///   and telemetry then removes the handler and emits
///   `[telemetry, handler, failure]`. So does a crash in `run` or in
///   `on_failure`.
///
/// Panics when `events` is empty or names one event twice.
pub fn handler(
  events: List(Event(m, d)),
  run: fn(Event(m, d), m, d) -> Result(Nil, e),
  on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
) -> Subscription {
  case events {
    [] -> panic as "sinal.handler: no events"
    _ -> Nil
  }
  case first_repeated(list.map(events, fn(event) { event.name }), []) {
    Ok(repeated) ->
      panic as {
        "sinal.handler: event "
        <> string.inspect(list.map(repeated, atom.to_string))
        <> " is listed twice"
      }
    Error(Nil) -> Nil
  }
  let names = list.map(events, fn(event) { event.name })
  let callback = fn(name, raw_measurements, raw_metadata) {
    dispatch(name, raw_measurements, raw_metadata, events, run, on_failure)
  }
  Subscription(id: None, install: fn(id) {
    ffi.telemetry_attach_many(id, names, callback)
  })
}

/// Gives the handler a stable native handler id instead of a fresh one, so
/// that an Erlang or Elixir caller can `:telemetry.detach(id)` it. `attach`
/// returns `AlreadyExists` while another handler holds the id.
///
/// Panics when `id` is empty.
pub fn with_id(subscription: Subscription, id: String) -> Subscription {
  case id {
    "" -> panic as "sinal.with_id: the handler id is empty"
    _ -> Subscription(..subscription, id: Some(id))
  }
}

/// Installs a subscription until `detach`. Starts the `telemetry`
/// application when it is not running.
pub fn attach(subscription: Subscription) -> Result(Attachment, AttachError) {
  let Subscription(id:, install:) = subscription
  let raw_id = case id {
    Some(id) -> ffi.to_dynamic(id)
    None -> ffi.unique_handler_id()
  }
  case install(raw_id), id {
    Ok(Nil), _ -> Ok(Attachment(raw_id))
    Error(Nil), Some(id) -> Error(AlreadyExists(id))
    Error(Nil), None -> panic as "sinal.attach: a fresh handler id was taken"
  }
}

/// Removes a handler. Returns `Error(Nil)` when it was not attached: it was
/// detached before, or telemetry removed it after it failed.
pub fn detach(attachment: Attachment) -> Result(Nil, Nil) {
  ffi.telemetry_detach(attachment.id)
}

/// A group of subscriptions for `with_subscriptions`.
pub opaque type SubscriptionPlan {
  SubscriptionPlan(
    entries: List(Subscription),
    exception_cleanup_reporter: fn(SubscriptionCleanupFailure) -> Nil,
  )
}

/// A cleanup failure of the subscription at zero-based `index`.
pub type SubscriptionCleanupFailure {
  SubscriptionCleanupFailure(index: Int, failure: CleanupFailure)
}

/// `with_subscriptions` could not attach the subscription at `index`; the
/// work did not run, and the subscriptions before it were detached.
pub type SubscriptionScopeError {
  SubscriptionAttachFailed(
    index: Int,
    error: AttachError,
    rollback_failures: List(SubscriptionCleanupFailure),
  )
}

/// The work's result and the handlers that did not detach cleanly. Read it
/// by label; sinal may add fields.
pub type SubscriptionCompletion(a) {
  SubscriptionCompletion(
    work_result: a,
    cleanup_failures: List(SubscriptionCleanupFailure),
  )
}

/// Plans a scope over `entries`, attached in list order and detached in
/// reverse order.
pub fn subscriptions(entries: List(Subscription)) -> SubscriptionPlan {
  SubscriptionPlan(entries, fn(_) { Nil })
}

/// Reports cleanup failures that happen while the work's exception is
/// being re-raised; such failures cannot be returned. The default reporter
/// does nothing. A reporter that crashes does not mask the work's
/// exception.
pub fn with_exception_cleanup_reporter(
  plan: SubscriptionPlan,
  reporter: fn(SubscriptionCleanupFailure) -> Nil,
) -> SubscriptionPlan {
  SubscriptionPlan(..plan, exception_cleanup_reporter: reporter)
}

/// Attaches the plan's subscriptions in order, runs `work`, and detaches
/// them in reverse order.
///
/// - When an attach fails, `work` does not run, the earlier subscriptions
///   are detached, and the error names the failing index.
/// - When `work` raises (error, exit or throw), every subscription is
///   detached and the exception is re-raised with its class, reason and
///   stacktrace.
/// - Attaching is not atomic: a concurrent emitter can see a partial set.
///   Detaching does not wait for a handler already running in another
///   process. A killed process skips cleanup.
pub fn with_subscriptions(
  plan: SubscriptionPlan,
  work: fn() -> a,
) -> Result(SubscriptionCompletion(a), SubscriptionScopeError) {
  case
    acquire_subscriptions(plan.entries, 0, [], plan.exception_cleanup_reporter)
  {
    Ok(cleanups) ->
      Ok(ffi_with_subscription_scope(
        work,
        cleanups,
        plan.exception_cleanup_reporter,
      ))
    Error(error) -> Error(error)
  }
}

/// Describes an attach failure for logs.
pub fn describe_attach_error(error: AttachError) -> String {
  case error {
    AlreadyExists(id) ->
      "a handler with id " <> string.inspect(id) <> " is already attached"
  }
}

/// Describes a handler failure for logs, with `describe` for the handler's
/// own error.
pub fn describe_handler_failure(
  failure: HandlerFailure(e),
  describe: fn(e) -> String,
) -> String {
  case failure {
    MalformedMeasurements(error) ->
      "malformed measurements: " <> fields.describe_error(error)
    MalformedMetadata(error) ->
      "malformed metadata: " <> fields.describe_error(error)
    HandlerReturned(error) ->
      "the handler returned an error: " <> describe(error)
  }
}

/// Describes a cleanup failure for logs.
pub fn describe_cleanup_failure(failure: CleanupFailure) -> String {
  case failure {
    AlreadyDetached -> "the handler was already detached"
    DetachCrashed(description) -> "detaching crashed: " <> description
  }
}

/// Describes a scope failure for logs.
pub fn describe_scope_error(error: SubscriptionScopeError) -> String {
  let SubscriptionAttachFailed(index:, error:, rollback_failures:) = error
  let rollback = case rollback_failures {
    [] -> ""
    failures ->
      "; rollback failed for "
      <> string.join(
        list.map(failures, fn(failure) {
          "subscription "
          <> int.to_string(failure.index)
          <> " ("
          <> describe_cleanup_failure(failure.failure)
          <> ")"
        }),
        ", ",
      )
  }
  "subscription "
  <> int.to_string(index)
  <> " did not attach: "
  <> describe_attach_error(error)
  <> rollback
}

fn name_atoms(name: List(String), caller: String) -> List(Atom) {
  case name {
    [] -> panic as { caller <> ": the event name is empty" }
    _ ->
      list.map(name, fn(segment) {
        grammar.to_atom(segment, caller:, what: "name segment")
      })
  }
}

fn first_repeated(
  names: List(List(Atom)),
  seen: List(List(Atom)),
) -> Result(List(Atom), Nil) {
  case names {
    [] -> Error(Nil)
    [name, ..rest] ->
      case list.contains(seen, name) {
        True -> Ok(name)
        False -> first_repeated(rest, [name, ..seen])
      }
  }
}

fn dispatch(
  event_name: List(Atom),
  raw_measurements: Dynamic,
  raw_metadata: Dynamic,
  events: List(Event(m, d)),
  run: fn(Event(m, d), m, d) -> Result(Nil, e),
  on_failure: fn(Event(m, d), HandlerFailure(e)) -> Nil,
) -> Nil {
  case list.find(events, fn(event) { event.name == event_name }) {
    Error(Nil) -> ffi.raise_callback_failure("unrecognized_event_descriptor")
    Ok(event) ->
      // A decode failure skips this one invocation. Raising would make
      // telemetry detach the handler for good, losing every later event.
      case fields.decode(event.measurements, raw_measurements) {
        Error(error) -> on_failure(event, MalformedMeasurements(error))
        Ok(measurements) ->
          case fields.decode(event.metadata, raw_metadata) {
            Error(error) -> on_failure(event, MalformedMetadata(error))
            Ok(metadata) ->
              case run(event, measurements, metadata) {
                Ok(Nil) -> Nil
                Error(error) -> {
                  on_failure(event, HandlerReturned(error))
                  ffi.raise_callback_failure("handler_returned_error")
                }
              }
          }
      }
  }
}

type BeamException

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
  cleanups: List(#(Int, fn() -> Result(Nil, Nil))),
  on_cleanup_failure: fn(SubscriptionCleanupFailure) -> Nil,
  exception: BeamException,
) -> a

@external(erlang, "sinal_scope_ffi", "cleanup_subscriptions")
fn cleanup_subscriptions(
  cleanups: List(#(Int, fn() -> Result(Nil, Nil))),
) -> List(SubscriptionCleanupFailure)

@external(erlang, "sinal_scope_ffi", "with_subscription_scope")
fn ffi_with_subscription_scope(
  work: fn() -> a,
  cleanups: List(#(Int, fn() -> Result(Nil, Nil))),
  on_cleanup_failure: fn(SubscriptionCleanupFailure) -> Nil,
) -> SubscriptionCompletion(a)

fn acquire_subscriptions(
  subscriptions: List(Subscription),
  index: Int,
  cleanups: List(#(Int, fn() -> Result(Nil, Nil))),
  on_exception_cleanup_failure: fn(SubscriptionCleanupFailure) -> Nil,
) -> Result(List(#(Int, fn() -> Result(Nil, Nil))), SubscriptionScopeError) {
  case subscriptions {
    [] -> Ok(cleanups)
    [subscription, ..rest] ->
      case ffi_acquire_subscription(fn() { attach(subscription) }) {
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

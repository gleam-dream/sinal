//// Carries a raised BEAM exception, with its class, reason and stacktrace,
//// so that it can be reported or raised again unchanged.
////
//// `sinal` reports a `BeamException` as `DetachRaisedException` when a
//// detach raised during the cleanup of `with_attachments` or
//// `with_subscriptions`. Use `exception_class` to classify it and `reraise`
//// to raise it again with its original reason and stacktrace. The reason
//// and stacktrace are not exposed as Gleam values.

/// An opaque BEAM exception representation that preserves exact class, reason,
/// and stacktrace across the FFI boundary without JSON serialization.
pub type BeamException

pub type ExceptionClass {
  ErrorClass
  ExitClass
  ThrowClass
}

@external(erlang, "sinal_scope_ffi", "exception_class")
pub fn exception_class(exception: BeamException) -> ExceptionClass

@external(erlang, "sinal_scope_ffi", "reraise")
pub fn reraise(exception: BeamException) -> a

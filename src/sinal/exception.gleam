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

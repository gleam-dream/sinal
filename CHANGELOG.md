# Changelog

## Unreleased — initial release

- Add BEAM-only typed events and field codecs backed by native `:telemetry` 1.4.2. Handlers receive decoded measurements and metadata synchronously; malformed input or handler failure follows native failure notification and detachment.
- Add explicit attachments, same-shaped multi-event attachments, and scoped subscriptions. Subscriptions acquire sequentially, roll back earlier registrations on failure, and report cleanup failures while retaining successful work results. Catchable exceptions are re-raised with their original class, reason, and stacktrace.
- Add native spans with typed start, stop, and exception descriptors. `run_span_result` retains a completed business result if completion instrumentation cannot be encoded; `run_span` uses a raising policy for encoding failures.

The supported target is Erlang/BEAM. The manifest requires Gleam 1.18 or newer and pins `telemetry` 1.4.2; CI exercises Gleam 1.18.1 and OTP 28. JavaScript is unsupported. Delivery is synchronous, handler order is unspecified, detach does not wait for callbacks already running, and uncatchable process termination can bypass scoped cleanup. Export and buffering are outside this library. The package version remains unchanged until a release decision.

# Upstream Oracle Provenance: `telemetry` 1.4.2

## Pinned upstream facts

- **Package:** `telemetry` 1.4.2 (Hex package: `https://hex.pm/packages/telemetry/1.4.2`)
- **Hex tarball URL:** `https://repo.hex.pm/tarballs/telemetry-1.4.2.tar`
- **Hex outer checksum:** `928F6495066506077862C0D1646609EED891A4326BEE3126BA54B60AF61FEBB1`
- **Source repository:** `https://github.com/beam-telemetry/telemetry`
- **Upstream git tag:** `v1.4.2`
- **Exact source commit:** `7baf8085e406d5ae9e43b284d7c866742ae04b28`
- **Direct upstream source URLs:**
  - Main module: `https://github.com/beam-telemetry/telemetry/blob/7baf8085e406d5ae9e43b284d7c866742ae04b28/src/telemetry.erl` (tagged: `https://github.com/beam-telemetry/telemetry/blob/v1.4.2/src/telemetry.erl`)
  - App descriptor: `https://github.com/beam-telemetry/telemetry/blob/7baf8085e406d5ae9e43b284d7c866742ae04b28/src/telemetry.app.src`
- **Direct upstream test URLs:**
  - Common Test suite: `https://github.com/beam-telemetry/telemetry/blob/7baf8085e406d5ae9e43b284d7c866742ae04b28/test/telemetry_SUITE.erl` (tagged: `https://github.com/beam-telemetry/telemetry/blob/v1.4.2/test/telemetry_SUITE.erl`)
  - Test helper suite: `https://github.com/beam-telemetry/telemetry/blob/7baf8085e406d5ae9e43b284d7c866742ae04b28/test/telemetry_test_SUITE.erl` (tagged: `https://github.com/beam-telemetry/telemetry/blob/v1.4.2/test/telemetry_test_SUITE.erl`)
- **License:** Apache License 2.0 (`https://github.com/beam-telemetry/telemetry/blob/7baf8085e406d5ae9e43b284d7c866742ae04b28/LICENSE`)
- **Baseline execution command:** `cd build/upstream/telemetry && rebar3 ct`
- **Baseline execution outcome:** Pass — 42 test cases passed (0 failures).

## Adopted test provenance table

| Sinal test                                              | Upstream file + case                      | Source commit / License                                 | Normalization                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | Matched semantic                                                                                                                                                                                     |
| ------------------------------------------------------- | ----------------------------------------- | ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `test/focused_behavior.gleam` (`focused_behavior.main`) | `test/telemetry_SUITE.erl:invoke_handler` | `7baf8085e406d5ae9e43b284d7c866742ae04b28` / Apache-2.0 | Replaces dynamic Erlang terms and untyped atom lists with typed `Event(m, d)`, `Fields(m)`, `Fields(d)`, and typed `Handler(m, d, e)`. Replaces process mailbox receive assertion with synchronous subject delivery assertion verifying: (1) exact selected event name identity `["sinal", "test", "event"]`, (2) exact decoded measurement `count == 42`, (3) exact decoded metadata `user == "alice"`, and (4) callback execution PID equals emitter PID (`emitter_pid == current_pid`). | Synchronous invocation of attached handler upon event emission in the emitting process with decoded measurement and metadata maps. Currently red at the honest `sinal.attach` named `todo` boundary. |

## Upstream case coverage ledger

Upstream test suite: `telemetry_SUITE.erl` (41 test cases across `ets` and `persisted` groups, plus `persist_with_existing_handlers`) and `telemetry_test_SUITE.erl` (1 test case).

| Upstream case                               | Upstream group / function | Sinal status                                        | Reason / Planned wave                                                                                            |
| ------------------------------------------- | ------------------------- | --------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------- |
| `persist_with_existing_handlers`            | root                      | Planned                                             | Requires persistent_term migration verification after native registration                                        |
| `bad_event_names`                           | `ets`, `persisted`        | Planned                                             | Type system rejects non-atom lists statically; FFI rejects empty or invalid lists                                |
| `duplicate_attach`                          | `ets`, `persisted`        | Planned                                             | Native attach returns `Error(AlreadyExists)` on duplicate ID                                                     |
| `invoke_handler`                            | `ets`, `persisted`        | Ported (Red cycle in `test/focused_behavior.gleam`) | Synchronous dispatch with typed measurement and metadata decoding, asserted emitting PID, and clean detachment   |
| `list_handlers`                             | `ets`, `persisted`        | Planned                                             | Introspection query over native registry                                                                         |
| `list_for_prefix`                           | `ets`, `persisted`        | Planned                                             | Prefix lookup in native registry                                                                                 |
| `detach_on_exception`                       | `ets`, `persisted`        | Planned                                             | Callback error/exit/throw removal plus `[telemetry, handler, failure]` notification                              |
| `no_execute_detached`                       | `ets`, `persisted`        | Planned                                             | Detached handlers receive no further events                                                                      |
| `no_execute_on_prefix`                      | `ets`, `persisted`        | Planned                                             | Exact-name matching vs prefix matching semantics                                                                 |
| `no_execute_on_specific`                    | `ets`, `persisted`        | Planned                                             | Prefix emission does not trigger child handlers                                                                  |
| `handler_on_multiple_events`                | `ets`, `persisted`        | Planned                                             | `attach_many` dispatch to multiple event descriptors                                                             |
| `remove_all_handler_on_failure`             | `ets`, `persisted`        | Planned                                             | Handler failure removes all registrations under that ID                                                          |
| `list_handler_on_many`                      | `ets`, `persisted`        | Planned                                             | Listing multi-event registrations                                                                                |
| `detach_from_all`                           | `ets`, `persisted`        | Planned                                             | Detaching multi-event attachment removes from all events                                                         |
| `old_execute`                               | `ets`, `persisted`        | Excluded                                            | Legacy Erlang 2-argument `telemetry:execute/2` without metadata is obsolete and excluded from typed Sinal facade |
| `default_metadata`                          | `ets`, `persisted`        | Planned                                             | Empty metadata default handling                                                                                  |
| `off_execute`                               | `ets`, `persisted`        | Planned                                             | Zero-handler emission no-op behavior and overhead                                                                |
| `invoke_successful_span_handlers`           | `ets`, `persisted`        | Planned                                             | `run_span` start/stop event emission and duration timing                                                         |
| `invoke_exception_span_handlers`            | `ets`, `persisted`        | Planned                                             | `run_span` exception event emission and exact re-raise                                                           |
| `spans_generate_unique_default_contexts`    | `ets`, `persisted`        | Planned                                             | Default `telemetry_span_context` generation per invocation                                                       |
| `logs_on_local_function`                    | `ets`, `persisted`        | Excluded                                            | Erlang anonymous local function warnings are not applicable to Gleam closures                                    |
| `telemetry_test_SUITE:assert_receive_event` | `telemetry_test`          | Planned                                             | Test helper assertion parity                                                                                     |

## Expected-Red Catalog

| Focused command                                       | Public behavior under test                                                                                                                                                                                                                       | Expected failure site and message                                                 | Observed failure                                                                                                                                                                            | Removal condition                                                                                                                                 |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------- |
| `nix develop --command gleam run -m focused_behavior` | Synchronous invocation of attached handler upon event emission in emitting process with exact decoded measurements (`count == 42`), exact decoded metadata (`user == "alice"`), and matching emitting PID (`report.emitter_pid == current_pid`). | `src/sinal.gleam:170`: `todo as "native telemetry attach is not yet implemented"` | Exit code 1: `runtime error: todo: native telemetry attach is not yet implemented` at `sinal.attach src/sinal.gleam:170` called from `focused_behavior.main test/focused_behavior.gleam:61` | Implement native `:telemetry.attach/4` and `:telemetry.execute/3` FFI handlers in `sinal.gleam` and `sinal_ffi.erl` in the first green TDD cycle. |

## Scaffold-Warning Inventory

These 6 named `todo` warnings represent deliberate, unreached executable boundaries in the compile-green scaffold, distinct from the expected-red test failure above:

1. `src/sinal.gleam:160`: `todo as "native telemetry emit is not yet implemented"` — type signature and field encoding scaffolded; native `:telemetry.execute/3` dispatch deferred.
2. `src/sinal.gleam:170`: `todo as "native telemetry attach is not yet implemented"` — handler types, validation, and detachment scaffolded; native `:telemetry.attach/4` registration deferred (entry point for first red test).
3. `src/sinal.gleam:183`: `todo as "native telemetry attach_many is not yet implemented"` — multi-event signature and duplicate native name validation scaffolded; native `:telemetry.attach_many/4` deferred.
4. `src/sinal.gleam:201`: `todo as "scoped attachment lifetime is not yet implemented"` — scoped signature and error types scaffolded; native temporary attachment lifecycle deferred.
5. `src/sinal/span.gleam:155`: `todo as "span event descriptor derivation is not yet implemented"` — span prefix and reserved field validation enforced; deriving start/stop/exception descriptors deferred.
6. `src/sinal/span.gleam:171`: `todo as "native telemetry run_span is not yet implemented"` — timing types and completion result signatures scaffolded; native `:telemetry.span/3` call deferred.

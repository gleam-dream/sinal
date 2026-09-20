# Expected-Red Catalog

This document records the durable expected-red catalog for the initial Sinal checkpoint, capturing the focused behavior test, its expected failure site and message, observed failure, and removal condition, alongside the scaffold-warning inventory.

## Expected-Red Cases

| Focused command                                       | Public behavior under test                                                                                                                                                                                                                       | Expected failure site and message                                                 | Historical observed failure                                                                                                                                                                 | Resolution status                                                                                                                                                             |
| ----------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `nix develop --command gleam run -m focused_behavior` | Synchronous invocation of attached handler upon event emission in emitting process with exact decoded measurements (`count == 42`), exact decoded metadata (`user == "alice"`), and matching emitting PID (`report.emitter_pid == current_pid`). | `src/sinal.gleam:170`: `todo as "native telemetry attach is not yet implemented"` | Exit code 1: `runtime error: todo: native telemetry attach is not yet implemented` at `sinal.attach src/sinal.gleam:170` called from `focused_behavior.main test/focused_behavior.gleam:61` | **Resolved Green in Wave 2** via native `:telemetry.attach_many/4` and `:telemetry.execute/3` FFI handlers in `src/sinal.gleam` and `src/sinal_ffi.erl`. Command now exits 0. |

## Detailed Case Entry

### Case: `focused_behavior.main` (synchronous dispatch and decoded values)

- **Focused command:** `nix develop --command gleam run -m focused_behavior`
- **File:** `test/focused_behavior.gleam`
- **Public behavior under test:**
  1. Define a typed `Event` with atom keys `[sinal, test, event]` and typed fields `count` (Int) and `user` (String).
  2. Attach a typed handler with `sinal.attach(handler_id, event, handler, on_failure)` that sends an observed `DeliveryReport` back to the test subject.
  3. Emit the event synchronously via `sinal.emit(event, 42, "alice")`.
  4. Receive and assert delivery report:
     - `report.selected_event_name == ["sinal", "test", "event"]`
     - `report.count == 42`
     - `report.user == "alice"`
     - `report.emitter_pid == current_pid` (verifies same-process synchronous execution)
  5. Detach cleanly via `sinal.detach(attachment)`.
- **Expected failure site:** `src/sinal.gleam:170`
- **Expected failure message:** `todo as "native telemetry attach is not yet implemented"`
- **Historical observed failure output:**
  ```text
  runtime error: todo

  native telemetry attach is not yet implemented

  stacktrace:
    sinal.attach src/sinal.gleam:170
    focused_behavior.main test/focused_behavior.gleam:61
  ```
- **Historical exit code:** 1
- **Resolution:** Resolved green in Wave 2. Native telemetry execution and attachment implemented in `src/sinal.gleam` and `src/sinal_ffi.erl`. `gleam run -m focused_behavior` now exits with code 0.

## Scaffold-Warning Inventory

With native telemetry dispatch, attachment, and scoped lifetime implemented in Wave 2, only 2 named `todo` warnings remain for unreached executable boundaries in spans (Wave 3 scope):

1. `src/sinal/span.gleam:155`: `todo as "span event descriptor derivation is not yet implemented"` — span prefix and reserved field validation enforced; deriving start/stop/exception descriptors deferred to Wave 3.
2. `src/sinal/span.gleam:171`: `todo as "native telemetry run_span is not yet implemented"` — timing types and completion result signatures scaffolded; native `:telemetry.span/3` call deferred to Wave 3.

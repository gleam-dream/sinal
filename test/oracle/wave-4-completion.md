# Wave 4 Completion Report: Initial Release Completion

- **Repository:** `/code/gleam-dream/sinal`
- **Branch:** `master`
- **Starting HEAD:** `13105a1777d01d6e1904ae624409ff2f25c739aa`
- **Status:** Complete reviewed release candidate facade; 0 production todos; all review findings closed.

---

## 1. Review 3 Findings Closed

1. **Stacktrace Origin Frame Fidelity & Span Exception Equality:**
   - Caught exception stacktraces for `error`, `exit`, and `throw` verify stable origin frames (`scope_test_ffi:raise_test_error/1`, `raise_test_exit/1`, `raise_test_throw/1`) via `has_origin_frame`.
   - In `run_span_exception_reraise_and_event_test`, verified that `exception_stacktrace_to_dynamic(exc_meta.stacktrace)` is identical to the re-raised exception's native stacktrace via `term_equals` and contains the exact origin frame.
   - Asserted that exactly one terminal exception event is emitted and zero extra events arrive.
2. **Full Handler-Failure Payload Evidence:**
   - Asserted that the failure listener receives the exact event name `[telemetry, handler, failure]`.
   - Asserted that `rec.handler_config` equals `nil` (`ffi.to_dynamic(Nil)`), proving full native contract exposure across all failure scenarios (malformed measurements, malformed metadata, declared handler errors, and unexpected callback crashes).
3. **Barrier-Controlled In-Flight Detach Race:**
   - Replaced sequential detach with `detach_in_flight_barrier_race_test`: emitter process enters callback, callback creates reply subject and signals coordinator via barrier, coordinator detaches while callback is actively in flight, callback finishes cleanly, post-detach emissions cannot invoke handler, and repeated detach returns `Error(NotAttached)`.
   - Added `overlapping_subscriptions_order_independent_test`: multiple single and multi-event subscriptions verified order-independently.
   - Added `public_id_replacement_after_detach_test`: verifies handler ID can be re-registered after detachment.
4. **Native Span-Owned Value Inspection:**
   - Unwrapped dynamic span values and verified with native predicates:
     - `start_meas.system_time` is a positive Erlang integer (`is_positive_integer`).
     - `start_meas.monotonic_time`, `stop_meas.monotonic_time`, and `exc_meas.monotonic_time` are native Erlang integers (`is_native_integer`).
     - `stop_meas.duration` and `exc_meas.duration` are non-negative Erlang integers (`is_non_negative_integer`).
     - `SpanContext` is a native Erlang reference (`is_native_reference`), preserved within an invocation (`ctx_start == ctx_stop`), and distinct across invocations (`ctx1 != ctx2`).

---

## 2. Bounded Stress Harness & Microbenchmarks

- **Bounded Stress Suite (`test/stress_test.gleam`):**
  - Repeated attach/emit/detach churn (50 rapid sequential cycles with unique IDs).
  - High-throughput concurrent flood (10 concurrent worker processes emitting 50 events each = 500 events total with exact accounting and zero dropped events).
  - Concurrent spans (20 concurrent worker spans verifying within-worker start/stop context equality, valid native BEAM reference semantics, and mutual distinctness across all workers via `list.unique` cardinality and all-pairs inequality).
  - Runs in ~0.25s during `gleam test` and standalone via `gleam run -m stress_test`.
- **Reproducible Microbenchmarks (`test/benchmark.gleam`):**
  - **Zero-handler emission:** ~75 ns/op (~13.1M ops/sec).
  - **Single-handler synchronous emission + decode:** ~238 ns/op (~4.1M ops/sec).
  - **Pure typed codec encode + decode:** ~147 ns/op (~6.7M ops/sec).
  - **Native span execution (start + stop events + context):** ~353 ns/op (~2.8M ops/sec).
  - Standalone executable via `gleam run -m benchmark`.

---

## 3. Documentation & Compile-Checked Examples

- Comprehensive `README.md` including:
  - Complete architecture, atom trust, synchronous caller execution, failure isolation, and empirical microbenchmark baseline (avoiding unsupported claims of zero serialization overhead or native speed preservation).
  - Verified usage examples with reproducible extraction check:
    - `test/readme_example_test.gleam` serves as the runnable source of truth, compiling all published examples.
    - Fixed `EncodingFailed(fields.FieldEncodeError(msg)) -> panic as msg` so `msg` binds the inner String rather than treating the error record as a String.
    - Fixed `fields.pair` and `fields.imap` sequencing.
    - Resolved all identifiers in scoped attachment and span query examples (`scoped_metrics_example`, `query_meta_fields`, `run_database_query`, `execute_traced_query`).
    - Added automated verification test `readme_snippets_match_source_test` that reads `README.md`, extracts all 5 published Gleam snippets, and asserts they appear verbatim in `test/readme_example_test.gleam`.
    - `readme_example_flow_test` and `readme_span_example_test` execute all example functions against live `:telemetry` in `gleam test`.
  - Operational limits: non-quiescent detach, uncatchable termination (abrupt VM exits or kill bypass cleanup; scoped attachments narrow cleanup to ordinary return and catchable error/exit/throw), unspecified handler order, persistent_term migration, adapter-owned export/buffering.
  - Explicit Target and Support Matrix: BEAM / Erlang native only (reviewed release candidate tested on OTP 28 and :telemetry 1.4.2); JavaScript explicitly unsupported.
- `gleam docs build` passes cleanly, generating HTML docs to `build/dev/docs/sinal/index.html`.
- `gleam export hex-tarball` dry-run passes cleanly, generating `build/sinal-0.1.0.tar`.

---

## 4. Test Suite and Gate Summary

- `gleam format --check src test`: 0 errors.
- `gleam check`: 0 errors, 0 warnings.
- `gleam test`: 47 passed, 0 failures.
- `gleam run -m focused_behavior`: exits 0.
- `gleam run -m stress_test`: exits 0.
- `gleam run -m benchmark`: exits 0.
- `nix flake check`: treefmt check passes.
- Production todos: 0 in `src/`.
- Release blockers: 0. Initial facade is complete and verified across 47 tests, bounded stress, and microbenchmarks.

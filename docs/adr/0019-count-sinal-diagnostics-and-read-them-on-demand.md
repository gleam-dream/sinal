<a id="adr-0019"></a>

# 0019: Count sinal diagnostics and read them on demand

Date: 2026-11-25
Status: Accepted

## Context

Sinal detects two conditions of its own on hot paths: an emitted value missing from its `fields.enum` list, and an `observe` or `subscription` invocation skipped because a native map did not decode. Either can repeat on every occurrence of an event. Logging each occurrence made the producer's latency depend on the logger and let whoever triggers the condition choose the log volume.

A first design logged one warning and emitted a counted telemetry event when the total reached 1, 2, 4, 8 and each later power of two. Occurrences after the last power of two stayed unreported until the condition recurred, so the tail of a burst was never observable. Flushing that tail would need a timer or a process, which an observation library should not own.

## Decision

Log one warning on the first occurrence of each condition for an event name, and only count later occurrences in a node-wide atomic counter. `sinal.diagnostics()` returns every condition that occurred, with its exact total. Reading does not reset a counter. Sinal emits no diagnostic event and runs no timer.

## Consequences

- Counts are always exact and observable whenever someone reads them. The hot path costs one atomic increment after the first occurrence.
- An application or adapter that wants periodic reports polls `diagnostics()` and forwards the totals to its own reporter; it derives a rate by subtracting its previous reading. Without a poll, only the first warning is visible.
- No reset function exists. A reset would let one reader hide counts from another; a reader that wants deltas keeps its own previous reading.
- Reading scans the node's persistent terms, so it suits an occasional poll, not a hot path.

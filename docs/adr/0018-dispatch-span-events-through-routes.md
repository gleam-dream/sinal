# Dispatch span events through routes

<a id="adr-0018"></a>

- A span's start, stop and exception events follow forwarder routes exactly as `sinal.emit` does. There is one dispatch behaviour for every Sinal occurrence and no separate routed span function.
- Spans used to delegate to native `telemetry:span/3`, which calls `telemetry:execute/3` and so runs every handler in the producer. The reason given, that start and stop must share a process to measure duration, holds for the measurement and not for handler dispatch. A library instrumented with spans therefore could not be isolated by the route its application chose for the library's prefix, and a slow handler ran inline twice per call.
- An opt-in routed span beside the native one was rejected: it keeps two behaviours for one kind of occurrence, and the application, which chooses routes, cannot make a library choose the routed variant.
- Sinal implements the span protocol of the pinned `telemetry` 1.4.2 itself: the same monotonic and system clocks, a fresh reference as `telemetry_span_context` unless the metadata supplies one, the same measurement and metadata keys, and the original exception re-raised with its class, reason and stacktrace. The producer reads the clocks, runs the work and re-raises; only the dispatch of each event is routed. Unrouted spans behave as before, which the native oracle tests check.
- A routed exception event copies the exception reason and stacktrace to the forwarder, and a routed span adds one admission and one message per event. A full or unavailable forwarder drops a span event as it drops any routed event, so a handler can see a start without its stop.

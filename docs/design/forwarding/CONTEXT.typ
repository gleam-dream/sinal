#let terms = (
  (slug: "term-forwarder", title: [Forwarder], body: [An immutable configuration for a named, capacity-bounded telemetry execution process. Its running process lifetime is a forwarder incarnation.]),
  (slug: "term-forwarder-incarnation", title: [Forwarder incarnation], body: [One running lifetime of a forwarder process, with its own event destination and admission counters.]),
  (slug: "term-admission-target", title: [Admission target], body: [The direct event destination, capacity and fresh admission counters that one incarnation publishes together. A producer that read an old target can reach only that incarnation.]),
  (slug: "term-route", title: [Route], body: [A node-wide binding from an event-name prefix to a forwarder. The most specific matching prefix selects the destination.]),
  (slug: "term-in-flight-event", title: [In-flight event], body: [A forwarded occurrence admitted to one incarnation whose dispatch has not finished. Capacity includes both queued and executing occurrences.]),
  (slug: "term-refusal", title: [Refusal], body: [The immediate typed rejection of an occurrence because the destination is full or unpublished. A refusal is neither retried nor delivered inline.]),
  (slug: "term-drop-report", title: [Drop report], body: [A best-effort observation of capacity refusals, unavailable destinations, and a restart's estimate of lost in-flight events. It is a diagnostic count rather than a delivery receipt.]),
)

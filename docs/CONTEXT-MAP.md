# Sinal context map

## Contexts

- [Observation](design/observation/CONTEXT.typ) owns typed event definitions, field codecs, registration, subscription scopes, correlation and native spans.
- [Forwarding](design/forwarding/CONTEXT.typ) owns the supervised forwarder, per-incarnation admission, drop reports and node-wide prefix routes.
- [Verification](design/verification/CONTEXT.typ) owns the native oracle, validation profiles, race probes and benchmark method that produce evidence for the other two contexts.

## Relationships

- Forwarding is the customer of Observation (`customer/supplier`). It dispatches occurrences that Observation encodes and selects, and it takes event definitions and codecs from Observation without redefining them.
- Verification is a conformist to Observation and Forwarding (`conformist`). It adopts their public contracts as written and judges them without altering their vocabulary.
- A term shared across contexts names exactly one owning context. Observation owns `term-event`, `term-fields` and `term-correlation`; Forwarding owns `term-forwarder` and `term-route`; Verification owns `term-native-oracle`.

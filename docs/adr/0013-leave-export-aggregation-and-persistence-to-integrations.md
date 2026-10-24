# Leave export, aggregation and persistence to integrations

<a id="adr-0013"></a>

- Sinal supplies typed native observation and optional bounded forwarding. External export, metric aggregation, durable queues, trace propagation and confirmed delivery belong to adapters that own their own capacity and shutdown policy.
- Native introspection and `persist/0` stay available to raw BEAM callers, and Sinal adds no typed wrapper. Tests that use them prove interoperability without widening the public facade.
- Folding export into the package would move business authority and retention into an observation library. Forwarding would then imply a delivery guarantee that it deliberately does not give.
- The package version stays at 0.1.0 until a release decision is taken. The package keeps no changelog and no prose usage guide: the design layer, these records and the compiled usage examples ([ADR 0014](0014-document-usage-as-compiled-examples-and-keep-reference-docs.md)) replace the unpublished construction diary, and no earlier release exists to migrate from.

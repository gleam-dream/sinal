#import ".render/designlib.typ": *

#let title = [Sinal: typed native telemetry]
#let accent = "slate"
#let index_only = true

#let body = [
  #section(title: "Foundation", lead: "Observations report facts and never decide them.", body: [
    #no-goal(title: "Observations do not control package state")[Sinal does not decide authorization, retries, job progress, approval, workflow resume or compensation. Emitting a fact does not certify durable state or command success.]
    #no-goal(title: "Export and trace parentage belong to adapters")[External export, metric aggregation, unbounded buffering, trace propagation and handler recovery policy belong to applications or adapters. Sinal has no JSON Schema dependency or universal lifecycle event.]
    #principle(title: "Keep diagnostics separate from business authority")[Correlations join observations rather than authorize work. Drop counts explain delivery limits rather than prove which effects occurred.]
    #principle(title: "Make operational limits visible to callers")[Process placement, resource retention, absence, refusal and cleanup remain observable contracts across every context. A convenient constructor does not imply delivery, quiescence or durability.]
  ])

  #section(title: "System at a glance", lead: "Three contexts divide typed observation, bounded forwarding and verification.", body: [
    #diagram(altitude: "L1", viewpoint: "runtime", title: "Observation ownership and execution", flow: "top-to-bottom", accent: accent,
      groups: ((id: "observation", label: "Observation context", kind: "bounded-context", tint: "teal"), (id: "forwarding", label: "Forwarding context", kind: "bounded-context", tint: "violet"), (id: "application", label: "Application ownership", kind: "runtime", tint: "slate"), (id: "telemetry", label: "Native telemetry", kind: "runtime", tint: "slate")),
      nodes: (
        (id: "producer", label: "Application or library", sub: "owns business facts", kind: "external-system", group: "application", tint: "slate"),
        (id: "definition", label: "Definitions and codecs", kind: "component", group: "observation", tint: "teal"),
        (id: "emit", label: "Emit and route lookup", kind: "component", group: "observation", tint: "teal"),
        (id: "scope", label: "Registration and scopes", kind: "component", group: "observation", tint: "teal"),
        (id: "span", label: "Native spans", kind: "component", group: "observation", tint: "teal"),
        (id: "forwarder", label: "Bounded forwarder", kind: "component", group: "forwarding", tint: "violet"),
        (id: "native", label: "Native telemetry", sub: "shared handler registry", kind: "external-system", group: "telemetry", tint: "slate"),
        (id: "handler", label: "Application handler", sub: "owns interpretation and export", kind: "external-system", group: "application", tint: "slate"),
      ), edges: (
        (from: "producer", to: "definition", relation: "dependency", label: "uses typed definitions"),
        (from: "producer", to: "emit", relation: "call", label: "emit"),
        (from: "producer", to: "scope", relation: "call", label: "attach or scope"),
        (from: "producer", to: "span", relation: "call", label: "instrument work"),
        (from: "emit", to: "native", relation: "call", label: "unrouted"),
        (from: "emit", to: "forwarder", relation: "dataflow", label: "routed admission"),
        (from: "scope", to: "native", relation: "call", label: "attach and detach"),
        (from: "span", to: "native", relation: "call", label: "start and terminal"),
        (from: "forwarder", to: "native", relation: "call", label: "dispatch"),
        (from: "native", to: "handler", relation: "call", label: "decode then invoke"),
      ), caption: [The boundaries mark each context's responsibility rather than a process. Unrouted callbacks share the producer process; forwarded callbacks share the forwarder process. Native spans and drop reports bypass routes.],
    )
    #points(
      [#ctx("observation") owns #term("term-event"), #term("term-fields") and #term("term-correlation"). Its definitions allocate no event process and install no registration.],
      [Registration binds caller callbacks into #term("term-subscription") values and returns #term("term-attachment") handles. Scope orchestration owns ordered acquisition and reverse cleanup.],
      [Spans delegate timing and exception observation to native telemetry. #ctx("forwarding") owns optional process separation and admission through the #term("term-forwarder"), while the #term("term-route") table remains node-wide application configuration.],
      [#ctx("verification") owns the #term("term-native-oracle"), the #term("term-validation-profile") and the executable evidence for the other two contexts.],
      [All runtime work occurs on one BEAM node. There is no network transport, persistent event journal or cross-node registration; multiple nodes install independent handlers and routes.],
    )
    #md-table(2, (
      [Unit], [Owns and composes with],
      [Definitions and codecs (observation)], [Names, trusted keys, caller types, foreign decoding and emit-time enum diagnostics.],
      [Native dispatch and registrations (observation)], [Handler identity, event selection, typed failures, native exceptions and detach.],
      [Subscription scopes (observation)], [Heterogeneous acquisition, rollback, work lifetime and indexed cleanup.],
      [Correlation (observation)], [Bounded shared observation value and optional or required field encoding.],
      [Spans (observation)], [Independent start and stop types, reserved timing fields and one catchable terminal observation.],
      [Forwarding and routing (forwarding)], [Incarnation admission, best-effort delivery, drop reporting and prefix selection.],
      [Validation, oracle and benchmarks (verification)], [Gate profiles, native parity, public consumer obligations, race probes and measurement method.],
    ))
  ])

  #section(title: "Effects and extension contracts", lead: "Every effect has a local owner; observation never changes the source package's decision.", body: [
    #subsection(title: "Effect timing and decision points")[
      #md-table(3, (
        [Operation], [Before authoritative effect], [Effect and result boundary],
        [event/fields/span definition], [Validate source names, keys and role collisions; run pure placeholder plan], [Allocate native atoms and immutable codec closures; no registration or event process.],
        [subscription/plan], [Bind typed callbacks and validate selected names], [Retain closures only; no installed registry state.],
        [attach], [Select native identity; ensure telemetry application], [Registry mutation; successful reply returns its handle. A failed reply can leave uncertain mutation.],
        [emit], [Check enums, encode both native maps, select route], [Inline native dispatch or one admission/send attempt; no delivery receipt.],
        [with_subscriptions], [Acquire complete known plan], [Work runs, then cleanup; separate work and cleanup outcomes.],
        [span.run], [Encode start metadata], [Start, work, completion encoding, terminal observation and return/re-raise in one process.],
        [forwarder.new/supervised], [Obtain stable name counters; validate startup settings], [Publish incarnation target only after initialization; handlers execute later.],
        [route/unroute], [Validate trusted prefix], [Serialize node-wide binding update; in-flight old delivery persists.],
      ))
      #points(
        [The authoritative decisions are native registration success, selected codec admission, scope acquisition completion and forwarder admission. Native selection and dispatch do not confer business authority; a package emits only after its own decision point and keeps its result even if observation is refused.],
      )
    ]
    #subsection(title: "Caller codec and handler extension contract")[
      #contract(name: "Caller-owned codec and callback integration", mission: "Accept application values while retaining the shared native observation boundary.", accent: accent,
        answers: answers-data(
          responsibility: [The caller defines key meaning, enum completeness, encoder/decoder laws and captured-resource lifetime.],
          interface: [A custom field supplies a typed encoder and dynamic decoder; a typed handler supplies a fallible callback and failure observer before installation.],
          interactions: [Sinal owns naming admission, map classification, event selection, installation and native failure semantics.],
          invariants: [Caller extensions must not dynamically select keys, rely on decoder effects, change process placement or bypass the descriptor's map boundary.],
          failure: [Custom callback or codec exceptions remain native exceptions; typed handler errors retain caller e and native removal. Captured data can appear in native failure configuration.],
        ),
      )
      #points(
        [The extension contains no state type parameter beyond the caller's measurement, metadata, result and error values. Application configuration remains in ordinary closures, and differently shaped subscriptions can be grouped after their types are bound.],
        [Names and identifiers serve different purposes: event names select observation classes; stable handler ids select registration ownership; correlations join work; SpanContext joins one native invocation. None is an authorization credential or universal idempotency key.],
        [Re-emitting an occurrence has no deduplication or replay guarantee. Duplicate stable attachment refuses, repeated detach reports absence, identical route writes replace, and deterministic correlation derivation preserves value equality without suppressing occurrences.],
      )
    ]
    #subsection(title: "Exporter and tracing adapter boundaries")[
      #contract(name: "Observation export integration", mission: "Translate observations without moving business authority into the collector.", accent: accent,
        answers: answers-data(
          responsibility: [An adapter owns external serialization, safe attributes, aggregation, export transport, retry and retention.],
          interface: [It observes package-owned descriptors with ordinary typed handlers and supplies explicit process/buffering ownership.],
          interactions: [Sinal supplies native telemetry interoperability, correlation values and optional bounded forwarding; packages keep their independent runtime decisions.],
          invariants: [Absence, unknown measurements and native exception evidence are preserved according to an explicit adapter schema; observations do not resume or mutate work.],
          failure: [Export errors cannot be treated as source-command failure or delivery confirmation; the adapter must bound its own memory and recovery policy.],
        ),
      )
      #points(
        [No exporter implementation, traceparent protocol, metric schema or durable queue is specified inside Sinal. Those retained integration capabilities require their own adapter contracts; the current package does not silently satisfy them through forwarding.],
        [Blueprint, workflow persistence, model providers, MCP, prompt management and retrieval are not runtime participants in this context. They may emit caller-owned facts using Sinal, but their schemas, permissions and state remain owned by those packages.],
      )
    ]
    #subsection(title: "Deployment, security and retention")[
      #points(
        [Erlang/BEAM is the supported target; JavaScript is unsupported (#adr(12)) because the boundary uses native telemetry, maps, references, OTP processes, ETS, atomics and persistent_term. The package requires Gleam 1.18 or newer and supports telemetry 1.4.2 through later 1.x releases under the declared dependency range.],
        [Handler registry and routes belong to one node. Atom definitions and name-wide diagnostic counters can remain for its lifetime; attachment closure retention lasts until native removal, while queued event terms remain until dispatch or process death.],
        [No event payload size, native-map size, route-count, handler-count, capture-size or collector-history limit is enforced. Only correlation bytes, definition spelling and forwarder occurrence count have the explicit bounds described here.],
        [Security depends on source-trusted atom definitions and safe caller metadata. Native failure configuration exposes closures, and arbitrary exception terms can contain application details; exporters must select and redact safe fields under their own contract.],
        [Native telemetry's handler-table persistence is an in-memory runtime optimization rather than storage durability. There is no persistence adapter, transaction log or node-restart recovery layer to model; #adr(13) leaves export and persistence to integrations.],
      )
    ]
  ])

  #section(title: "End-to-end walkthrough", lead: "One application's work identifier survives process separation without controlling the work.", body: [
    #subsection(title: "A correlated request with bounded observation")[
      #points(
        [An application defines `[shop, request, finished]` with a duration measurement and metadata containing its route plus required correlation. It derives one correlation from its business request key and uses the named record pattern from Definitions and codecs.],
        [At application startup it installs a labelled typed observer, supervises one 1,024-capacity forwarder and routes `[shop]` to it. The observer sends safe records to the application's collector; it is installed once rather than once per request.],
        [The request code completes its own business operation and emits the resulting fact. Encoding and route selection happen in the producer, followed by one forwarder admission attempt; the business result remains the application's result regardless of refusal.],
      )
      #sequence(title: "Successful routed observation", accent: accent,
        participants: ((id: "request", label: "Request process", shape: "participant"), (id: "fwd", label: "Forwarder", shape: "queue"), (id: "native", label: "Native telemetry", shape: "control"), (id: "collector", label: "Typed observer", shape: "participant")),
        steps: (
          seq-msg("request", "request", "business decision completes"),
          seq-msg("request", "fwd", "encoded occurrence; admit within capacity"),
          seq-note("request", [Emit returns without waiting for a handler.]),
          seq-msg("fwd", "native", "execute in forwarder process"),
          seq-msg("native", "collector", "decode duration and correlated metadata"),
          seq-msg("collector", "native", "normal callback return", dashed: true),
          seq-msg("native", "fwd", "dispatch finished; release slot", dashed: true),
        ), caption: [The shared correlation is carried in metadata. The callback process is the forwarder and supplies no implicit request-local context.],
      )
      #points(
        [At capacity, the occurrence is dropped and counted as rejected. If the forwarder is unavailable it is counted as unavailable; a later running incarnation may emit the diagnostic report, but the application must not treat it as a per-request receipt.],
        [A malformed foreign occurrence of the same name notifies the failure observer and skips one callback. A handler-returned error removes the registration, while a process-level kill can stop the forwarder and cause a restart's best-effort lost report.],
        [Application shutdown removes its route and detaches the long-lived observer. Already admitted or selected callbacks can still finish, so collector resource release follows the application's own concurrency ownership rather than assuming detach establishes quiescence.],
      )
    ]
    #subsection(title: "A scoped diagnostic and a native span")[
      #points(
        [A test or explicit diagnostic call creates an ordered plan for the span's typed start and stop observers. Scope acquisition completes before work starts, and those native span observations remain inline even while the shop prefix is routed.],
        [A returned business Error produces stop and remains the work result. A catchable throw produces exception with the start context and re-raises its original evidence; scope cleanup then attempts every known registration and reports indexed failures without replacing that outcome.],
        [These examples compose observation ownership rather than creating a shared runtime. The source package still chooses when its business state changed, the application still chooses retention/export and Sinal still provides only typed native observation plus explicitly selected bounded forwarding.],
      )
    ]
  ])
]

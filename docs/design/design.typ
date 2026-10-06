#import ".render/designlib.typ": *

#let title = [Sinal: typed native telemetry]
#let accent = "teal"

#let body = [
  #section(title: "Foundation", lead: "Typed observation shares the native BEAM contract.", body: [
    #goal(title: "Emit and observe caller-owned Gleam values")[One event definition binds a native name to independent measurement and metadata codecs. Producers and observers reuse it without erasing their application records.]
    #goal(title: "Interoperate with native telemetry producers and handlers")[Erlang and Elixir code receives atom-list names and native maps. Foreign maps are decoded before typed handlers run.]
    #goal(title: "Provide explicit observation lifetimes and bounded forwarding")[Applications can own long-lived attachments, scoped groups, native spans and supervised forwarding. Forwarding bounds admitted occurrences while keeping observations best effort.]
    #no-goal(title: "Observations do not control package state")[Sinal does not decide authorization, retries, job progress, approval, workflow resume or compensation. Emitting a fact does not certify durable state or command success.]
    #no-goal(title: "Export and trace parentage belong to adapters")[External export, metric aggregation, unbounded buffering, trace propagation and handler recovery policy belong to applications or adapters. Sinal has no JSON Schema dependency or universal lifecycle event.]
    #invariant(title: "Typed handlers receive decoded declared values", enforcement: "mechanism")[Both maps must decode through the selected event before its typed callback runs. A malformed map is never passed as a partially decoded application value.]
    #invariant(title: "Admission never exceeds one incarnation's capacity", enforcement: "mechanism")[A forwarder's capacity includes queued and executing events. Its published destination and admission counter belong to the same running lifetime.]
    #invariant(title: "Work exceptions retain their original identity", enforcement: "mechanism")[Catchable work error, exit and throw retain class, reason and stacktrace through scoped cleanup and native span execution. Cleanup reporting cannot replace a work exception.]
    #invariant(title: "Atom-producing definitions come from trusted source", enforcement: "convention")[Event names, route prefixes and field keys must be source definitions. Grammar checks reject invalid spelling but cannot prove trust or bound the number of valid names.]
    #principle(title: "Preserve native ownership at the observation boundary")[The native registry owns handler selection and inline execution. Sinal supplies typed definitions and explicit application-selected isolation.]
    #principle(title: "Keep diagnostics separate from business authority")[Correlations join observations rather than authorize work. Drop counts explain delivery limits rather than prove which effects occurred.]
    #principle(title: "Make operational limits visible to callers")[Process placement, resource retention, absence, refusal and cleanup remain observable contracts. A convenient constructor does not imply delivery, quiescence or durability.]
  ])

  #pending-ledger(
      pending-entry(title: "Recover an attachment after an uncertain native call", kind: "ruling")[Native registry calls can raise or time out after their result becomes uncertain. A scope can clean up only registrations whose acquisition returned a handle; automatic identifiers are hidden from the caller when acquisition raises. No generation token, cancellation protocol or uncertain-acquisition recovery contract is specified.],
      pending-entry(title: "Trace parentage and propagation requirements", kind: "ruling")[A correlation can carry a trace identifier, but neither it nor a native span context carries parent-child semantics. Causation fields and OpenTelemetry propagation remain adapter-driven requirements to settle when that integration is designed; #adr(7) preserves the deferred scope.],
  )

  #section(title: "System at a glance", lead: "One typed telemetry context composes definitions, registration, scope, span and forwarding.", body: [
    #diagram(altitude: "L1", viewpoint: "runtime", title: "Observation ownership and execution", flow: "top-to-bottom", accent: accent,
      groups: ((id: "sinal", label: "Sinal ownership", kind: "bounded-context", tint: accent), (id: "application", label: "Application ownership", kind: "runtime", tint: "slate"), (id: "telemetry", label: "Native telemetry", kind: "runtime", tint: "slate")),
      nodes: (
        (id: "producer", label: "Application or library", sub: "owns business facts", kind: "external-system", group: "application", tint: "slate"),
        (id: "definition", label: "Definitions and codecs", kind: "component", group: "sinal", tint: accent),
        (id: "emit", label: "Emit and routes", kind: "component", group: "sinal", tint: accent),
        (id: "scope", label: "Registration and scopes", kind: "component", group: "sinal", tint: accent),
        (id: "span", label: "Native spans", kind: "component", group: "sinal", tint: accent),
        (id: "forwarder", label: "Bounded forwarder", kind: "component", group: "sinal", tint: accent),
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
      ), caption: [The boundary marks Sinal's responsibility rather than a process. Unrouted callbacks share the producer process; forwarded callbacks share the forwarder process. Native spans and drop reports bypass routes.],
    )
    #points(
      [Definitions own #term("term-event"), #term("term-fields") and #term("term-correlation"). They allocate no event process and install no registration.],
      [Registration binds caller callbacks into #term("term-subscription") values and returns #term("term-attachment") handles. Scope orchestration owns ordered acquisition and reverse cleanup.],
      [Spans delegate timing and exception observation to native telemetry. Forwarding owns optional process separation and admission, while routes remain node-wide application configuration.],
      [All runtime work occurs on one BEAM node. There is no network transport, persistent event journal or cross-node registration; multiple nodes install independent handlers and routes.],
    )
    #md-table(2, (
      [Unit], [Owns and composes with],
      [Definitions and codecs], [Names, trusted keys, caller types, foreign decoding and emit-time enum diagnostics.],
      [Native dispatch and registrations], [Handler identity, event selection, typed failures, native exceptions and detach.],
      [Subscription scopes], [Heterogeneous acquisition, rollback, work lifetime and indexed cleanup.],
      [Correlation], [Bounded shared observation value and optional or required field encoding.],
      [Spans], [Independent start/stop types, reserved timing fields and one catchable terminal observation.],
      [Forwarding and routing], [Incarnation admission, best-effort delivery, drop reporting and prefix selection.],
      [Verification and extensions], [Oracle fidelity, public consumer obligations, operational probes and adapter boundaries.],
    ))
  ])

  #section(title: "Observation model", lead: "Definitions, registrations and recorded occurrences have distinct ownership.", body: [
    #subsection(title: "Concept and relationship census")[This is one domain: typed telemetry. Ten model subjects describe its values and live ownership: event definition, field codec, correlation, subscription, attachment, scope, span definition, span invocation, forwarder incarnation and route table. Lifecycle states describe observable control flow rather than requiring those exact runtime records.
      #diagram(altitude: "L2", viewpoint: "domain-model", title: "Definitions and live lifetimes", accent: accent, flow: "top-to-bottom",
        nodes: (
          (id: "event", label: "Event definition", kind: "value-object", tint: accent),
          (id: "fields", label: "Field codec", kind: "value-object", tint: accent),
          (id: "correlation", label: "Correlation", kind: "value-object", tint: accent),
          (id: "subscription", label: "Subscription", kind: "value-object", tint: accent),
          (id: "attachment", label: "Attachment", kind: "entity", tint: accent),
          (id: "scope", label: "Subscription scope", kind: "aggregate", tint: accent),
          (id: "span", label: "Span definition", kind: "value-object", tint: accent),
          (id: "invocation", label: "Span invocation", kind: "entity", tint: accent),
          (id: "incarnation", label: "Forwarder incarnation", kind: "aggregate", tint: accent),
          (id: "routes", label: "Route table", kind: "aggregate", tint: accent),
        ), edges: (
          (from: "event", to: "fields", relation: "dependency", label: "1 : 2 codecs"),
          (from: "fields", to: "correlation", relation: "dependency", label: "0..n : 0..1 field values"),
          (from: "subscription", to: "event", relation: "dependency", label: "n : n selected definitions"),
          (from: "attachment", to: "subscription", relation: "dependency", label: "0..n : 1 installed description"),
          (from: "scope", to: "attachment", relation: "dependency", label: "1 : 0..n acquired registrations"),
          (from: "span", to: "event", relation: "dependency", label: "1 : 3 event roles"),
          (from: "invocation", to: "span", relation: "dependency", label: "0..n : 1 definition"),
          (from: "incarnation", to: "event", relation: "dataflow", label: "0..n : n occurrences"),
          (from: "routes", to: "incarnation", relation: "dependency", label: "1 : 0..n named destinations"),
        ), caption: [Edges describe typed definitions and ownership, rather than delivery order. A route names a forwarder even when no incarnation is running. A descriptor sharing a raw name with another descriptor does not establish global schema agreement.],
      )
    ]
    #subsection(title: "Immutable definitions and values")[
      #entity(title: "Event definition", description: [A reusable name and two codecs.], kind: "value-object", owner: "Definitions", lifecycle: "immutable", domain: "Typed telemetry", tint: accent)[
        #attribute(name: "Name", type: "Nonempty trusted event name", provenance: "authored")[Source-defined segments satisfying the name grammar.]
        #attribute(name: "Measurement shape", type: "Measurement field codec", provenance: "authored")[The caller measurement value and its native keys.]
        #attribute(name: "Metadata shape", type: "Metadata field codec", provenance: "authored")[The caller metadata value and its native keys.]
        #relates(cardinality: "1 : n")[May be selected by many subscriptions.]
      ]
      #entity(title: "Field codec", description: [One declared native-map shape and caller value type.], kind: "value-object", owner: "Definitions", lifecycle: "immutable", domain: "Typed telemetry", tint: accent)[
        #attribute(name: "Declared keys", type: "Ordered distinct trusted keys", provenance: "derived")[Derived at definition from the field-composition plan.]
        #attribute(name: "Encoding and decoding", type: "Caller-value transformations", provenance: "authored")[Getters and decoders preserve the declared meaning of each field.]
        #relates(cardinality: "n : n")[Composes reusable field groups into event and span roles.]
      ]
      #entity(title: "Correlation", description: [One bounded observation identifier chosen by an application.], kind: "value-object", owner: "Correlation", lifecycle: "immutable", domain: "Typed telemetry", tint: accent)[
        #attribute(name: "Value", type: "UTF-8 text of one to 128 bytes", provenance: "authored")[Provided verbatim, derived from a key, or randomly generated before constructing the value.]
        #relates(cardinality: "1 : n")[May join many work-scoped observations.]
      ]
      #entity(title: "Subscription", description: [A typed callback bound to one or more same-shaped event definitions.], kind: "value-object", owner: "Registration", lifecycle: "immutable", domain: "Typed telemetry", tint: accent)[
        #attribute(name: "Selected events", type: "Nonempty distinct event-name set", provenance: "authored")[Every selected definition has the same measurement and metadata type parameters.]
        #attribute(name: "Callbacks", type: "Handler and typed failure observer", provenance: "authored")[Closures can capture independent caller-owned configuration.]
        #attribute(name: "Identity preference", type: "Fresh identity or nonempty stable identity", provenance: "authored")[A readable label may decorate fresh identity; stable identity overrides the label.]
        #relates(cardinality: "1 : n")[May be installed repeatedly as distinct fresh attachments.]
      ]
      #entity(title: "Span definition", description: [The three typed event roles surrounding instrumented work.], kind: "value-object", owner: "Spans", lifecycle: "immutable", domain: "Typed telemetry", tint: accent)[
        #attribute(name: "Name prefix", type: "Nonempty trusted event name", provenance: "authored")[The start, stop and exception role suffixes extend this prefix.]
        #attribute(name: "Caller shapes", type: "Start metadata, extra stop measurements and stop metadata", provenance: "authored")[Independent types prevent an implicit transfer of start fields into stop metadata.]
        #relates(cardinality: "1 : n")[Defines arbitrarily many independent invocations.]
      ]
    ]
    #subsection(title: "Registration lifetime")[Native registration owns this lifecycle. An attachment's handle does not mutate when native telemetry removes its registration; its status is observed by lookup and detach.
      #state-type(id: "attachment-status", title: "Registration status", variants: ("vacant", "attached", "detached", "failed"))
      #entity(id: "attachment", title: "Attachment", description: [A handle to one native handler identifier.], kind: "entity", owner: "Native registry", lifecycle: "stateful", domain: "Typed telemetry", tint: accent)[
        #attribute(name: "Identifier", type: "Node-local native handler identifier", provenance: "derived")[Derived at successful installation, or taken from the caller's stable identity.]
        #attribute(id: "status", name: "Status", type: "Registration status", provenance: "observed", state-type: "attachment-status", state-machine: "attachment-lifecycle")[The current registry relationship; it is not cached authority inside the handle.]
        #relates(cardinality: "n : 1")[Installs one subscription description.]
      ]
      #state-machine(id: "attachment-lifecycle", subject: "attachment", state-field: "status", state-type: "attachment-status", title: "Native registration transitions", accent: accent, states: ("vacant", "attached", "detached", "failed"), initial: "vacant", accepting: ("detached", "failed"), transitions: (("vacant", "attached", "successful attach"), ("attached", "attached", "malformed occurrence skipped"), ("attached", "detached", "detach or registry shutdown"), ("attached", "failed", "handler failure removes registration")), caption: [A duplicate stable identifier refuses a new acquisition and leaves the existing registration unchanged. Reusing an identifier creates a new registration; a stale handle can detach that replacement.])
    ]
    #subsection(title: "Scope lifetime")[A scope owns only attachments whose acquisitions completed successfully. A typed refusal skips work; a catchable exception leaves through cleanup and re-raise.
      #state-type(id: "scope-status", title: "Scope status", variants: ("acquiring", "working", "cleaning", "completed", "refused", "raised"))
      #entity(id: "scope", title: "Subscription scope", description: [One ordered acquisition and cleanup operation.], kind: "aggregate", owner: "Scope orchestration", lifecycle: "stateful", domain: "Typed telemetry", tint: accent)[
        #attribute(name: "Plan", type: "Ordered subscription plan", provenance: "authored")[Includes the exceptional cleanup reporter.]
        #attribute(name: "Acquired registrations", type: "Indexed successful attachments", provenance: "derived")[Derived at acquisition and stored newest first for reverse cleanup.]
        #attribute(id: "status", name: "Status", type: "Scope status", provenance: "derived", state-type: "scope-status", state-machine: "scope-lifecycle")[Derived from the current acquisition, work or cleanup step.]
        #relates(cardinality: "1 : 0..n")[Owns acquired attachments until cleanup is attempted.]
      ]
      #state-machine(id: "scope-lifecycle", subject: "scope", state-field: "status", state-type: "scope-status", title: "Scoped acquisition and cleanup", accent: accent, flow: "top-to-bottom", states: ("acquiring", "working", "cleaning", "completed", "refused", "raised"), initial: "acquiring", accepting: ("completed", "refused", "raised"), transitions: (("acquiring", "acquiring", "one registration succeeds"), ("acquiring", "working", "all acquired"), ("acquiring", "cleaning", "refusal or acquisition exception"), ("working", "cleaning", "return or catchable exception"), ("cleaning", "completed", "return retained with cleanup failures"), ("cleaning", "refused", "typed acquisition refusal"), ("cleaning", "raised", "original exception re-raised")), caption: [Cleanup outcome does not replace the work outcome. An untrappable kill, node loss or VM loss can interrupt any nonterminal state without following a cleanup transition.])
    ]
    #subsection(title: "Span invocation lifetime")[One native context identifies each invocation. The terminal choice is the work's normal return or catchable exception, independent of observation callback success.
      #state-type(id: "span-status", title: "Span invocation status", variants: ("not-started", "running", "stopped", "exception"))
      #entity(id: "span-invocation", title: "Span invocation", description: [One native execution of a span definition.], kind: "entity", owner: "Native span runtime", lifecycle: "stateful", domain: "Typed telemetry", tint: accent)[
        #attribute(name: "Context", type: "Native span context", provenance: "derived")[Created at invocation and shared by its start and terminal occurrences.]
        #attribute(id: "status", name: "Status", type: "Span invocation status", provenance: "derived", state-type: "span-status", state-machine: "span-lifecycle")[Derived from native execution flow.]
        #attribute(name: "Timing", type: "System time, monotonic time and native duration", provenance: "observed")[Observed from the BEAM runtime; duration is a difference of monotonic readings.]
        #relates(cardinality: "n : 1")[Runs one span definition.]
      ]
      #state-machine(id: "span-lifecycle", subject: "span-invocation", state-field: "status", state-type: "span-status", title: "Normal return and exception choose different terminals", accent: accent, states: ("not-started", "running", "stopped", "exception"), initial: "not-started", accepting: ("stopped", "exception"), transitions: (("not-started", "running", "start occurrence emitted"), ("running", "stopped", "work returns a completion"), ("running", "exception", "catchable error, exit or throw")), caption: [A returned application Error is normal completion. Uncatchable process termination can prevent any terminal occurrence.])
    ]
    #subsection(title: "Forwarder and route lifetime")[Admission authority belongs to the running incarnation. The application owns route configuration and supervision; a forwarder value survives an incarnation without carrying its admission rights.
      #state-type(id: "incarnation-status", title: "Forwarder incarnation status", variants: ("initializing", "published", "stopped"))
      #entity(id: "forwarder-incarnation", title: "Forwarder incarnation", description: [One process lifetime with one published admission target.], kind: "aggregate", owner: "Forwarding", lifecycle: "stateful", domain: "Typed telemetry", tint: accent)[
        #attribute(name: "Name", type: "Application-owned node-local process name", provenance: "authored")[Stable across supervised restarts and reused by name-wide diagnostics.]
        #attribute(name: "Capacity", type: "Positive in-flight occurrence limit", provenance: "authored")[Validated before the target is published.]
        #attribute(name: "Target", type: "Direct subject and fresh admission counters", provenance: "derived")[Created at initialization and published as one incarnation-owned value.]
        #attribute(id: "status", name: "Status", type: "Forwarder incarnation status", provenance: "derived", state-type: "incarnation-status", state-machine: "incarnation-lifecycle")[Publication authorizes admission; process death removes publication.]
        #relates(cardinality: "1 : 0..n")[Owns accepted in-flight occurrences until dispatch finishes or the process dies.]
      ]
      #state-machine(id: "incarnation-lifecycle", subject: "forwarder-incarnation", state-field: "status", state-type: "incarnation-status", title: "Publication is the admission boundary", accent: accent, states: ("initializing", "published", "stopped"), initial: "initializing", accepting: ("stopped",), transitions: (("initializing", "published", "validated target published"), ("initializing", "stopped", "invalid capacity or name collision"), ("published", "published", "admit, dispatch or report"), ("published", "stopped", "shutdown or process death")), caption: [A restart creates a new machine instance. A delayed producer can send only to the direct subject it previously read, never to the replacement subject.])
      #entity(title: "Route table", description: [The application's node-wide event-prefix bindings.], kind: "aggregate", owner: "Application route configuration", lifecycle: "stateful", domain: "Typed telemetry", tint: accent)[
        #attribute(name: "Bindings", type: "Unique prefixes with named forwarder destinations", provenance: "authored")[Route replaces exactly one prefix; unroute removes exactly one prefix.]
        #attribute(name: "Selection order", type: "Longest-prefix-first ordering", provenance: "derived")[Derived at each update; lookup selects the first matching prefix.]
        #relates(cardinality: "1 : 0..n")[Names destinations regardless of whether a process is currently running.]
      ]
      #points(
        [The route table has set membership and replacement operations rather than a single status field. Its transition contract is absent → bound, bound → replaced, and bound → absent for one exact prefix; unrelated bindings survive each operation.],
      )
    ]
    #subsection(title: "Public sums and record boundaries")[These sums classify observable failure; diagnostic strings are descriptions rather than machine-readable decisions. Public returned records are read by label, so callers must not infer a frozen positional representation.
      #md-table(2, (
        [Public type], [Meaning and cases],
        [FieldError], [NotAMap; MissingField(key); InvalidField(key, decoder errors). First failure follows declaration order.],
        [AttachError], [AlreadyExists(id). Unexpected native availability, startup or call exceptions are not folded into this sum.],
        [HandlerFailure(e)], [MalformedMeasurements; MalformedMetadata; HandlerReturned(e). Error values remain caller-owned.],
        [CleanupFailure], [AlreadyDetached; DetachCrashed(description). Scope cleanup retains the failing zero-based plan index.],
        [SubscriptionScopeError], [SubscriptionAttachFailed(index, attach error, rollback failures). Work never ran.],
        [SubscriptionCompletion(a)], [The normal work value and reverse-cleanup failure list. A value of Result.Error is still a normal work value.],
        [CorrelationError], [EmptyCorrelation; CorrelationTooLong(actual bytes, maximum bytes).],
        [Forwarder Refusal], [CapacityExceeded; ForwarderUnavailable. Both mean the occurrence was refused rather than retried.],
        [Dropped and DroppedMetadata], [Rejected, lost and unavailable counts plus the forwarder's native name as text. Counts are diagnostic estimates.],
        [Span Completion], [The work result, extra stop measurements and independent stop metadata.],
        [Span event records], [Start/stop/exception measurements and metadata retain separate role types; native time wrappers and context stay opaque.],
        [ExceptionKind and TimeUnit], [Error/Exit/Throw classify native exceptions; Native/Nanosecond/Microsecond/Millisecond/Second select conversion units.],
      ))
      #points(
        [There is no stored business aggregate, journaled command, persisted lifecycle or transactional event stream. Observations are transient occurrences; the native registry, routes and diagnostic counters are node-local runtime state.],
      )
    ]
  ])

  #section(title: "Definitions and codecs", lead: "Caller types cross the native-map boundary without compulsory serialization.", body: [
    #answers(title: "Definition and codec contracts", accent: accent,
      responsibility: [Bind trusted event identity and field meaning to caller-owned values.],
      interface: [`event`, name/codecs accessors, primitive `Fields`, `include`, `success`, `optional`, `enum`, `field`, `encode`, `decode`, `check` and `keys`.],
      interactions: [Native dispatch, spans and direct forwarding share the same codecs; foreign callbacks always decode.],
      invariants: [Names are nonempty; grammar-valid declared keys are unique in one map; separate measurement and metadata maps can reuse a key.],
      failure: [Source-definition defects panic at construction; malformed maps return FieldError; caller codec exceptions remain BEAM exceptions.],
    )
    #subsection(title: "Name admission and atom ownership")[
      #points(
        [Each event-name segment and field key matches `[a-z][a-z0-9_]{0,62}` before atom creation at definition. Event and span names are nonempty; an empty route prefix is permitted because it intentionally selects every event.],
        [Validation is per segment, with a maximum of 63 ASCII bytes. There is no name-segment-count limit, key-count limit, descriptor-count limit or node atom-count quota.],
        [A valid dynamically generated tenant name can still create unbounded permanent atoms. Applications must keep variability in metadata values rather than event names, field keys or route prefixes; #adr(2) records the source-definition boundary.],
      )
      #behavior(title: "Invalid source definitions fail before use", area: "Definitions and codecs", level: "boundary")[
        #given[a definition has an invalid or empty required name, duplicate declared key, invalid optional shape, ambiguous enum name, reserved span key or duplicate selected event]
        #when[the caller constructs the definition]
        #then[construction raises a programmer-error diagnostic naming the offending definition]
        #then[the definition cannot be used to install a handler or emit an occurrence]
      ]
    ]
    #subsection(title: "Native field representation")[
      #md-table(3, (
        [Codec], [Encoded value], [Decode contract],
        [`string`], [UTF-8 binary], [Accept the Gleam string decoder's binary representation.],
        [`int`], [Integer], [Accept an integer.],
        [`float`], [Float], [Accept a float or an integer converted to float.],
        [`bool`], [Boolean atom], [Accept a boolean.],
        [`enum`], [The caller naming function's UTF-8 binary], [Accept that binary or an existing atom whose text matches a declared value name.],
        [`field`], [Any caller-encoded BEAM term], [Run the caller's dynamic decoder at one declared key.],
        [`optional`], [None omits its only key; Some writes the inner value], [Absent key, nil or undefined means None; every other term uses the inner decoder.],
        [`empty` or `success`], [Empty map], [Require a map and return the fixed success value while ignoring unrelated keys.],
      ))
      #points(
        [Native map keys are atoms, not binary aliases. Extra foreign keys are ignored, while a missing required key and an invalid present value remain distinct errors.],
        [`optional` requires exactly one declared key. Its inner encoding must not use native `nil` or `undefined` as meaningful present values because those markers denote absence.],
        [`fields.encode` runs the declared getters and encoders against an empty native map. Its type has no operational error return; this does not protect the caller from a crashing custom getter, encoder or decoder.],
      )
      #behavior(title: "Foreign values are checked at every typed boundary", area: "Definitions and codecs", level: "boundary")[
        #when[a caller decodes a foreign occurrence's declared map shape]
        #then[unrelated keys do not alter the declared value]
        #then[a non-map, absent required field or invalid present field returns a distinct classified failure]
      ]
    ]
    #subsection(title: "Record composition and effect timing")[
      #points(
        [`include(field, then:, get:)` combines the field's keys with the remaining record's keys in declaration order. The getter extracts the encoded value, while the bound decoded value enters the labelled record constructor in `success`.],
        [A nested record codec flattens its declared keys into the same native map. A duplicate across any flattened group panics at definition, while declaration order determines the first reported decode or enum-check failure.],
        [The encoding plan is built once by running the continuation with placeholder values. `field` obtains its placeholder by running the custom decoder against `nil` while discarding decode errors; therefore the decoder and builder can execute at definition before any observation exists.],
        [Decoding reruns the continuation with actual decoded values. The process-local decoding marker prevents eager reconstruction of encoding plans during that pass and is restored after either return or exception; nested decoding preserves the surrounding marker.],
        [Field selection must not depend on a prior bound value. Such selection could give the definition-time encoder and occurrence-time decoder different shapes; the public builder is intended to contain `include` calls and one `success` constructor with pure getters and decoders.],
      )
      #code-block("gleam", "pub type Delivery { Delivery(route: String, status: Int) }\n\npub fn delivery_fields() -> fields.Fields(Delivery) {\n  use status <- fields.include(fields.int(\"status\"), get: fn(m) { m.status })\n  use route <- fields.include(fields.string(\"route\"), get: fn(m) { m.route })\n  fields.success(Delivery(route:, status:))\n}")
      #points(
        [Here constructor labels preserve the route/status relationship despite the opposite declaration order. This is the canonical record example for this layer; #adr(6) records the removed positional hazard.],
      )
    ]
    #subsection(title: "Enum completeness and non-silent incompatibility")[
      #points(
        [`enum` requires a nonempty value list with unique encoded names. An exhaustive naming function does not prove that the list includes every constructor of the caller's type.],
        [Encoding an unlisted value still writes its name for native observers. `fields.check` returns InvalidField for that value, while the public emit paths log the same incompatibility in the producer process and still emit the occurrence.],
        [A typed observer's enum decoder rejects the unlisted name and skips that invocation. This is a definition-completeness risk rather than a delivery receipt or a handler-returned application error.],
      )
      #behavior(title: "An unlisted enum value remains diagnosable", area: "Definitions and codecs", level: "boundary")[
        #given[a caller value is absent from its enum's declared value list]
        #when[the caller emits that value]
        #then[the encoded name remains available to native observers]
        #then[the producer receives an incompatibility warning naming the event and field]
        #then[a typed observer reports malformed input and remains installed if its failure observer returns normally]
      ]
      #points(
        [Applications test every named constructor with `fields.check` and encode/decode roundtrips. Event measurement and metadata accessors expose codecs so these checks and exact native-map assertions require no registration; this obligation is not enforced by the compiler.],
      )
    ]
    #notes(title: "Implementation and behavioral evidence")[#lnk("../../src/sinal/fields.gleam")[Fields], #lnk("../../src/sinal/internal/name.gleam")[name admission], #lnk("../../src/sinal/internal/emit.gleam")[emit diagnostics], #lnk("../../test/sinal_test.gleam")[codec tests] and #lnk("../../test/decode_failure_test.gleam")[enum completeness tests] own the current executable boundary.]
  ])

  #section(title: "Native dispatch and registration", lead: "The native registry selects callbacks; Sinal selects and decodes their typed definition.", body: [
    #answers(title: "Native dispatch contracts", accent: accent,
      responsibility: [Translate typed values to native maps and bind selected definitions to installed callbacks.],
      interface: [`emit`, `observe`, `observe_labelled`, `subscription`, `handler`, `with_label`, `with_id`, `attach`, `detach` and failure descriptions.],
      interactions: [The native telemetry registry runs exported sinal_ffi:handle/4 with the typed closure as configuration. Routes optionally change the dispatch process.],
      invariants: [Selected event names are distinct inside one handler; one native identifier names one registration at a time; measurement decoding precedes metadata decoding and handler invocation.],
      failure: [Malformed input skips one invocation; returned handler error or callback exception removes the whole registration; native call failures can raise beyond AttachError.],
    )
    #subsection(title: "Emission authority and inline execution")[
      #points(
        [`sinal.emit` encodes measurements and metadata before looking up the longest matching route. With no route, native execute invokes selected handlers in the current producer process before returning Nil; #adr(1) records native ownership.],
        [A slow or blocked handler delays the producer without a Sinal deadline. Different producer processes may concurrently invoke the same handler, and the native registry supplies no order between handlers selected for one occurrence.],
        [The callback sees the native execution process as its `self()`. Process-dictionary state is whatever exists in that process; forwarding does not copy producer-local context, so work identity must travel as an explicit metadata field.],
        [Handler failure isolation covers catchable callback error, exit and throw. Arbitrary linked-process exits, untrappable kill, custom encoder exceptions or VM termination can still terminate the current process; a callback's failure isolation is not a guarantee against every action a handler can perform.],
      )
      #behavior(title: "Unrouted dispatch completes in the producer", area: "Native dispatch and registration", level: "boundary")[
        #given[the occurrence's name matches no route]
        #when[a producer emits the occurrence]
        #then[selected handlers execute in the producer's process before emission returns]
        #then[a catchable handler failure does not become the producer's application error]
      ]
      #points(
        [A descriptor constrains cooperating Gleam callers, not the node's raw name. Independent descriptors can share the same name with different codecs, and every typed callback therefore decodes rather than trusting the producer's type.],
      )
    ]
    #subsection(title: "Pure subscriptions and installed identity")[
      #points(
        [`observe` is the common infallible one-event path with a fresh identifier and warning logger for decode failures. `observe_labelled` adds a readable label without requiring label uniqueness or a typed attach result.],
        [`subscription` describes the same infallible callback without installing it. `handler` describes one fallible callback and failure observer for a nonempty list of same-shaped events; it returns the selected descriptor to both callbacks and refuses repeated names as definition bugs.],
        [Different measurement or metadata shapes belong in separate subscriptions. Their callbacks remain typed before the opaque Subscription values are grouped into a heterogeneous plan.],
        [Fresh native identity is `{sinal_handler, N}` or `{sinal_handler, Label, N}`, where N comes from a node-local positive unique integer. Labels accept arbitrary strings, create no atoms, and are diagnostic names rather than collision keys.],
        [`with_id` replaces the complete native identity with the supplied nonempty string. A duplicate returns AlreadyExists(id); a stable identity can be detached by raw native code, and labels do not decorate that stable identity.],
      )
      #behavior(title: "A duplicate stable identifier preserves the incumbent", area: "Native dispatch and registration", level: "boundary")[
        #given[the subscription's chosen identifier is already in use]
        #when[the caller attaches the subscription]
        #then[attachment is refused with the conflicting identifier]
        #then[the existing registration is unchanged]
      ]
      #points(
        [Subscription construction installs nothing, but opaque closures may retain caller resources. Applications bound the count and lifetime of subscriptions and captured values; no library subscription-count or capture-size limit exists.],
      )
    ]
    #subsection(title: "Decode failure, handler error and callback exception")[
      #md-table(3, (
        [Outcome], [Typed observer], [Native consequence],
        [Measurements fail to decode], [MalformedMeasurements; metadata decode and run are skipped], [Registration stays if failure observer returns.],
        [Metadata fails to decode], [MalformedMetadata; run is skipped], [Registration stays if failure observer returns.],
        [Run returns Ok], [No failure notification], [Registration remains.],
        [Run returns Error(e)], [HandlerReturned(e), then adapter raises], [Entire registration removed; native failure occurrence emitted.],
        [Run or failure observer raises], [Unexpected exception does not enter the caller's e], [Entire registration removed; native failure occurrence emitted.],
      ))
      #points(
        [The ordinary subscription logs a decode warning and retains the registration. A custom failure observer that raises converts even a malformed-data path into native callback failure; #adr(4) records the retained-handler rule and its earlier reversal.],
        [A multi-event registration fails as one identity. Failure during one selected event removes it from every selected event, while an unrelated registration continues to receive occurrences.],
        [Native `[telemetry, handler, failure]` metadata includes the triggering name, native handler identifier, callback configuration, exception class, reason and stacktrace. The configuration is the actual typed callback closure; captured application values are visible to native failure observers and handler-table introspection.],
        [Opaque Subscription and Attachment types do not make captured data secret from native code. Applications must avoid capturing credentials or other sensitive data they cannot expose to installed native observers; Sinal does not redact that native configuration.],
      )
      #behavior(title: "Malformed data skips one callback invocation", area: "Native dispatch and registration", level: "boundary")[
        #given[one selected occurrence has malformed measurements or metadata]
        #given[the failure observer returns normally]
        #when[the native registration receives the occurrence]
        #then[the typed work callback does not run for that occurrence]
        #then[the failure observer receives the classified decode failure and selected event]
        #then[later compatible occurrences can still reach the registration]
      ]
      #behavior(title: "A failed handler removes its whole registration", area: "Native dispatch and registration", level: "boundary")[
        #given[a selected typed handler returns an error or its callback raises]
        #when[native dispatch handles that failure]
        #then[the registration is removed from every selected event]
        #then[native failure observers receive the identifier, configuration and exception evidence]
      ]
    ]
    #subsection(title: "Startup, detach and registry races")[
      #points(
        [Attach checks the native handler-table process and starts the telemetry application through ensure_all_started when absent. Application-start failure raises a BEAM error; it is not AlreadyExists, and no standalone Sinal registry is created.],
        [Emit does not start telemetry. With no running native registry it reaches no handler; detach returns Error(Nil) when the registry or identifier is absent.],
        [Native attach and detach use the registry's ordinary synchronous call timeout, documented as 5,000 ms for the oracle. Registry death or a call timeout can raise, and a call whose reply is not received may have an uncertain mutation outcome.],
        [Detach removes future selection by identifier but does not wait for an already selected callback. A second detach reports absence rather than idempotent success.],
        [Handles are copyable and native removal has no compare-and-delete generation token. If a stable identity or deliberately inspected fresh identity is reused after removal, a stale handle can detach its replacement.],
        [Native `telemetry.persist/0` is available to Erlang/Elixir or a caller FFI and preserves registrations across its storage migration. Sinal intentionally exposes no additional persist wrapper or private introspection registry.],
      )
      #behavior(title: "Detach leaves selected callbacks able to finish", area: "Native dispatch and registration", level: "boundary")[
        #given[another process already selected the callback]
        #when[the caller detaches its registration]
        #then[later lookup cannot select that registration]
        #then[the selected callback may finish after detach returns]
      ]
    ]
    #notes(title: "Implementation and behavioral evidence")[#lnk("../../src/sinal.gleam")[Public dispatch and registration], #lnk("../../src/sinal_ffi.erl")[native registry boundary], #lnk("../../test/sinal_test.gleam")[native interoperability and failure tests] and #lnk("../../test/sinal_telemetry_start_test.gleam")[fresh-VM startup test] describe this boundary without claiming unknown-call recovery.]
  ])

  #section(title: "Subscription scopes", lead: "A scope retains work outcomes while making registration cleanup visible.", body: [
    #answers(title: "Scope ownership contracts", accent: accent,
      responsibility: [Acquire an ordered plan, run work only after complete acquisition, and attempt reverse cleanup.],
      interface: [`subscriptions`, `with_exception_cleanup_reporter`, `with_subscriptions`, indexed failure records and completion/error descriptions.],
      interactions: [Native attach/detach supply effects; the Erlang scope shim captures all catchable exception classes and preserves re-raise evidence.],
      invariants: [Every known successful acquisition receives a cleanup attempt on ordinary or catchable exit; cleanup never replaces the normal work value or original exception.],
      failure: [Typed acquisition refusal returns an indexed error plus rollback failures; acquisition/work exception re-raises after cleaning known registrations; untrappable termination can skip cleanup.],
    )
    #subsection(title: "Acquisition, rollback and completion")[
      #points(
        [A SubscriptionPlan may be empty and combines subscriptions with unrelated caller measurement, metadata and error types. Its exceptional cleanup reporter defaults to a silent callback.],
        [Acquisition follows list order with zero-based indexes. Each successful attach adds a cleanup closure to the front of the acquired list, fixing reverse cleanup order without a later sort.],
        [A typed refusal detaches all preceding successful acquisitions and returns SubscriptionAttachFailed with the failing index, AlreadyExists and rollback failures. Work does not run, and no later plan entry is attempted.],
        [If acquisition raises, the same rollback runs for known successful acquisitions before the original exception is re-raised. The failing attach itself may have an uncertain outcome, which is the unresolved recovery boundary in Pending updates.],
        [After ordinary work return, every acquired cleanup is attempted. SubscriptionCompletion retains the work result beside failures listed in reverse acquisition order; a returned business Error does not trigger exceptional cleanup.],
        [AlreadyDetached means the native registration was absent when cleanup ran, including removal after handler failure. That absence meets the removal objective but remains a visible cleanup failure rather than certifying that the handler stayed attached during work.],
      )
      #behavior(title: "A refused acquisition skips the scoped work", area: "Subscription scopes", level: "boundary")[
        #given[an earlier subset of the plan attached successfully]
        #when[a later subscription's attach is refused]
        #then[work is not invoked]
        #then[earlier successful registrations receive cleanup attempts in reverse order]
        #then[the result identifies the refused index and every failed rollback attempt]
      ]
      #behavior(title: "Normal completion retains independent cleanup failures", area: "Subscription scopes", level: "boundary")[
        #when[scoped work returns normally]
        #then[the returned work value is preserved]
        #then[all known registrations receive reverse-order cleanup attempts]
        #then[each failed cleanup remains indexed beside the work value]
      ]
    ]
    #subsection(title: "Exceptional cleanup and resource limits")[
      #points(
        [The scope shim catches error, exit and throw with their stacktrace. Each detach runs independently so one detach exception does not skip later cleanup attempts.],
        [A work or acquisition exception's cleanup failures reach the configured reporter because there is no completion result to return. A reporter exception is caught and discarded before re-raising the original work exception; #adr(5) records this outcome separation.],
        [Installation and removal are sequential rather than atomic. Concurrent emitters can see a partial registration set, and callbacks selected in another process can finish after scope exit.],
        [Captured resources must outlive independently executing callbacks, or applications must exclude concurrent emission during the scope. Scoped registration is suitable for explicit diagnostic/test lifetimes; it does not imply safe dynamic per-request subscriptions over a node-global event name.],
        [There is no work deadline, cleanup deadline or cancellation token in the scope API. A killed process or VM loss bypasses cleanup; normal native-call limits and user callback behavior still determine blocking.],
      )
      #behavior(title: "Cleanup reporting cannot replace a work exception", area: "Subscription scopes", level: "boundary")[
        #given[scoped work raises a catchable exception]
        #when[the scope attempts cleanup]
        #then[every known registration receives a cleanup attempt]
        #then[cleanup failures are offered to the configured reporter]
        #then[the original exception class, reason and stacktrace are re-raised even if the reporter raises]
      ]
    ]
    #notes(title: "Implementation and behavioral evidence")[#lnk("../../src/sinal.gleam")[Subscription acquisition], #lnk("../../src/sinal_scope_ffi.erl")[exception and cleanup shim], #lnk("../../test/api_control_test.gleam")[heterogeneous scope tests] and #lnk("../../test/sinal_test.gleam")[scope and in-flight detach tests] own the observable cases.]
  ])

  #section(title: "Correlation", lead: "A small shared value joins package-owned observations without owning their lifecycle.", body: [
    #answers(title: "Correlation contracts", accent: accent,
      responsibility: [Admit a bounded observation value and expose interoperable optional or required metadata fields.],
      interface: [`from_string`, `from_key`, `unique`, `to_string`, `field`, `required_field`, `max_bytes` and `describe_error`.],
      interactions: [Applications select the unit of work; emitting packages propagate the value explicitly across helper processes and called packages.],
      invariants: [The opaque value contains one to 128 UTF-8 bytes; optional and required field forms share one key and one present representation.],
      failure: [Verbatim empty or oversized input is refused; foreign invalid values fail decoding; randomness or crypto runtime failures can raise.],
    )
    #subsection(title: "Selection, validation and stable derivation")[
      #points(
        [`from_string` accepts one to 128 bytes verbatim and distinguishes empty from oversized input. The limit counts bytes rather than characters and therefore applies equally to multibyte external identifiers.],
        [`from_key` keeps a key that fits and hashes an empty or oversized key to 64 lowercase hexadecimal SHA-256 characters. The same key produces the same correlation across nodes and runs; every empty key therefore shares the same value.],
        [Stable hashing is suitable when application keys are used only for joining observations. A header or remote identifier that must remain verifiable verbatim uses `from_string`; hashing is not validation, authentication, secrecy or an injective identity protocol.],
        [`unique` draws 128 cryptographically random bits and emits 32 lowercase hexadecimal characters, redrawing an all-zero value. This has the shape of a W3C trace identifier and supplies probabilistic uniqueness rather than a coordinated global registry.],
        [Correlation is independent of package invocation ids and native SpanContext. Multiple calls of one business operation can share a correlation while keeping their own call/run/request identifiers; #adr(7) records the selected scope.],
      )
      #behavior(title: "Stable key derivation preserves joins", area: "Correlation", level: "boundary")[
        #when[the caller derives a correlation from an application key]
        #then[a key within the admitted byte range is preserved verbatim]
        #then[an empty or oversized key produces its deterministic digest]
        #then[repeated derivation of the same key produces the same value]
      ]
    ]
    #subsection(title: "Shared metadata contract and propagation")[
      #points(
        [The native key is the atom `correlation`; a present value is its UTF-8 binary. `field()` wraps required_field in a one-key optional codec, so None omits the key and foreign absent/nil/undefined values decode as None.],
        [`required_field()` decodes only a present binary within the admitted byte range. Optional and required readers interoperate for present values; a required reader rejects an absent value rather than inventing a correlation.],
        [A library generally accepts Option(Correlation) where work starts and copies it into every work-scoped occurrence and dependency call. Packages with an always-selected work value may use the required field; a Sinal observer must match the producer's possibility of absence.],
        [Start and stop span metadata are independent, so callers supply the correlation in both when terminal-only observers need it. Process-dictionary lookup and PID joins are not propagation contracts.],
        [Correlation has unbounded cardinality. Applications must not use it as a metric tag, and no Sinal limit bounds the number of distinct admitted values or records retained by an external collector.],
      )
      #behavior(title: "Required correlation readers reject absent values", area: "Correlation", level: "boundary")[
        #given[a selected occurrence supplies no correlation]
        #when[a required correlation observer decodes the metadata]
        #then[the typed callback is skipped with a missing-field failure]
        #then[the registration remains when its failure observer returns normally]
      ]
    ]
    #notes(title: "Implementation and public consumer evidence")[#lnk("../../src/sinal/correlation.gleam")[Correlation] and #lnk("../../test/correlation_test.gleam")[byte bounds and field interoperability] define the package boundary. The support_desk consumer carries a required ticket correlation across Fabric, Saga, HTTP Gun and LLM Wire; SSO Portal uses optional package values and labelled handlers rather than inferring identity from execution processes.]
  ])

  #section(title: "Native spans", lead: "Native telemetry owns timing while caller values keep separate event roles.", body: [
    #answers(title: "Span contracts", accent: accent,
      responsibility: [Define and run typed start, stop and exception observations around one synchronous work call.],
      interface: [`define`, `events`, `run`, Completion, role records, explicit time-unit readers and exception-term accessors.],
      interactions: [Native telemetry span/3 supplies clocks, context, terminal choice and exception re-raise; the same Fields codecs describe caller data.],
      invariants: [Protocol-owned keys cannot be overwritten; start and terminal share a context; ordinary work values produce stop rather than exception.],
      failure: [Reserved-key definitions panic; malformed foreign timing fails decoding; catchable work/encoding exception emits exception and re-raises, while uncatchable termination can omit a terminal.],
    )
    #subsection(title: "Event roles and owned fields")[
      #md-table(3, (
        [Role], [Measurements], [Metadata],
        [Start], [System time and monotonic time], [Caller start metadata plus telemetry_span_context.],
        [Stop], [Duration, monotonic time and caller extra measurements], [Caller stop metadata plus the same telemetry_span_context.],
        [Exception], [Duration and monotonic time], [Caller start metadata plus context, kind, native reason and stacktrace.],
      ))
      #points(
        [`events(span)` derives typed descriptors by appending start, stop and exception suffixes to one trusted name prefix. Each role can be observed independently, and native terms survive without JSON conversion.],
        [Extra stop measurements cannot declare duration or monotonic_time. Start metadata cannot declare telemetry_span_context, kind, reason or stacktrace, while stop metadata cannot declare telemetry_span_context.],
        [Start and stop caller metadata are independent. Stop does not inherit fields merely because they appeared at start; exception carries the start metadata with native exception details.],
        [Native context is opaque and supports equality. Context is shared within an invocation and distinct across invocations, while nested span contexts imply no parent-child trace relationship.],
        [SystemTime, MonotonicTime and NativeDuration wrap checked integer fields in separate types. Readers require an explicit TimeUnit; native conversion follows BEAM integer conversion semantics, and a foreign integer is not additionally constrained to a nonnegative duration by the decoder.],
        [ExceptionReason and ExceptionStacktrace retain arbitrary BEAM values behind opaque wrappers. Their explicit dynamic accessors are the escape boundary for applications that need native inspection.],
      )
    ]
    #subsection(title: "Execution, terminal selection and failure timing")[
      #points(
        [`run` encodes start metadata before entering native span execution. A custom encoder exception at that point prevents start and work execution.],
        [Native execution records the initial monotonic value, emits start inline, invokes work and uses its Completion result to encode extra stop measurements and stop metadata. Timing measures the native span interval and can include inline instrumentation delay; it is not promised to measure only the body.],
        [A normally returned Completion emits stop and returns its result unchanged. That result may itself be Result.Error, which is a business value rather than a raised exception.],
        [A catchable work exception, or a catchable exception while encoding its completion, follows native exception emission using start metadata, then re-raises its original triple. Completion encoders are caller code; the total encoder signature does not make them non-raising.],
        [Spans bypass every route and have no deadline or cancellation setting. A slow start/stop/exception handler can delay span execution even when other occurrences are routed, and an untrappable termination can prevent terminal delivery.],
      )
      #behavior(title: "Normal business errors end a span with stop", area: "Native spans", level: "boundary")[
        #given[work returns a completion whose business result is an error value]
        #when[the span completes normally]
        #then[stop is emitted with the caller's independent stop metadata]
        #then[the error value is returned unchanged]
        #then[no exception occurrence is emitted for that returned value]
      ]
      #behavior(title: "A catchable work exception retains native evidence", area: "Native spans", level: "boundary")[
        #when[instrumented work raises a catchable error, exit or throw]
        #then[the exception occurrence shares the start context and carries its class, reason and stacktrace]
        #then[the original exception is re-raised]
        #then[stop is not emitted for that invocation]
      ]
      #points(
        [Nested normal execution observes outer start, inner start, inner terminal and outer terminal. Handler order within any one occurrence remains unspecified, and separate processes need no global span order.],
      )
    ]
    #notes(title: "Implementation and behavioral evidence")[#lnk("../../src/sinal/span.gleam")[Typed native spans], #lnk("../../src/sinal_ffi.erl")[native span adapter], #lnk("../../test/sinal_test.gleam")[terminal, context and native-term tests] and #lnk("../../test/api_control_test.gleam")[explicit unit and malformed timing tests] retain the native semantics.]
  ])

  #section(title: "Bounded forwarding and routing", lead: "Applications choose process separation while each running incarnation owns admission.", body: [
    #answers(title: "Forwarding contracts", accent: accent,
      responsibility: [Run accepted occurrences in a separate named process without waiting for its handlers, and count best-effort refusal/loss diagnostics.],
      interface: [`new`, `with_capacity`, `supervised`, `emit`, `route`, `unroute`, `dropped_event`, Dropped and Refusal.],
      interactions: [OTP supervision owns process restarts; native telemetry still selects and runs handlers; node-wide route lookup selects an optional destination.],
      invariants: [Queued plus executing occurrences never exceed one incarnation's capacity; old senders cannot target a replacement; diagnostic reports bypass routes.],
      failure: [Full or unpublished targets refuse without wait/retry/fallback; process death loses pending work; report delivery is best effort; invalid capacity or target-name collision fails startup.],
    )
    #subsection(title: "Pure configuration and supervised startup")[
      #points(
        [`new(name)` creates no process and sets capacity to 1,024. It obtains name-wide diagnostic counters, so this constructor can allocate retained node-local counter state even though it does not start runtime execution.],
        [`with_capacity` changes the configured value. A capacity below one fails the supervised actor's initialization before publication; the initializer has a fixed 1,000 ms limit.],
        [`supervised` returns an OTP worker child specification whose startup result carries the Forwarder value. The application owns the supervisor, stable process name, shutdown policy and route registration.],
        [Startup creates fresh admission atomics and a direct event subject, drains name-wide diagnostics and publishes one target in a protected named ETS table owned by this incarnation. The ETS name is the same atom as the process name in the separate ETS namespace, so an existing table with that name fails initialization.],
        [User handlers run only after initialization from message handling. A producer before publication receives ForwarderUnavailable; startup never publishes a partially initialized admission target.],
        [One name creates retained shared diagnostic state for the node lifetime. Applications allocate names once at startup rather than per request; neither name count nor persistent_term memory has a Sinal quota.],
      )
    ]
    #subsection(title: "Admission and incarnation isolation")[
      #diagram(altitude: "L4", viewpoint: "runtime", title: "Admission separates live slots from restart diagnostics", flow: "top-to-bottom", accent: accent,
        groups: ((id: "live", label: "One forwarder incarnation", kind: "runtime", tint: accent), (id: "shared", label: "Application and shared node state", kind: "runtime", tint: "slate")),
        nodes: (
          (id: "sender", label: "Producer", kind: "external-system", group: "shared", tint: "slate"),
          (id: "target", label: "Published ETS target", sub: "subject + capacity + slots", kind: "component", group: "live", tint: accent),
          (id: "slots", label: "Fresh admission slots", kind: "component", group: "live", tint: accent),
          (id: "actor", label: "Direct event subject", sub: "queues then executes", kind: "queue", group: "live", tint: accent),
          (id: "counts", label: "Name-wide diagnostic atomics", sub: "survive incarnation death", kind: "component", group: "shared", tint: accent),
        ), edges: (
          (from: "sender", to: "target", relation: "call", label: "read coupled target"),
          (from: "sender", to: "slots", relation: "call", label: "increment then check"),
          (from: "sender", to: "actor", relation: "dataflow", label: "admitted occurrence"),
          (from: "sender", to: "counts", relation: "call", label: "diagnostic increment"),
          (from: "actor", to: "slots", relation: "call", label: "decrement after dispatch"),
        ), caption: [Only fresh incarnation slots authorize admission. Name-wide counts can be drained across restarts and never determine the replacement's capacity.],
      )
      #points(
        [A producer reads the direct subject, capacity and slots together. It atomically increments the local in-flight slot and refuses with CapacityExceeded if the result exceeds capacity, then rolls that increment back without sending the occurrence.],
        [Successful admission increments the separate name-wide in-flight diagnostic and sends directly to the captured subject. After native dispatch finishes, the incarnation decrements its local slot and floors the diagnostic decrement at zero.],
        [Increment-then-check may refuse a send that would fit under a different concurrent ordering. This safe spurious refusal is permitted near the boundary; admission never authorizes beyond capacity.],
        [The target table disappears with its owner process. A producer delayed after reading an old target can send only to that old direct subject and modify only its old slots; it cannot enqueue into the replacement incarnation.],
        [Ok(Nil) from direct forwarder.emit means admission and send, not completion or durable receipt. A process can die after lookup or admission; accepted occurrences may still be lost, and the restart's diagnostic estimate can undercount or overcount racing work.],
        [Capacity bounds event count, not message bytes, encoder allocations, captured handler data or downstream collector buffers. Values are encoded in the producer before admission, so even a refused oversized value has already been constructed and encoded.],
      )
      #behavior(title: "A full destination refuses without delaying its producer", area: "Bounded forwarding and routing", level: "boundary")[
        #given[the selected forwarder has no available admission capacity]
        #when[a producer hands it an occurrence]
        #then[the occurrence is refused and counted as rejected]
        #then[the producer does not wait for a handler or retry the occurrence]
      ]
      #behavior(title: "An unpublished destination refuses as unavailable", area: "Bounded forwarding and routing", level: "boundary")[
        #given[no initialized target is published for the named forwarder]
        #when[a producer attempts to emit to that destination]
        #then[the occurrence is refused and counted as unavailable]
        #then[the producer does not fall back to inline dispatch]
      ]
      #points(
        [#adr(8) records why incarnation-local authority is separate from diagnostics. The delayed-start, delayed-sender and delayed-drop probes synchronize the exact races instead of using elapsed sleeps as evidence.],
      )
    ]
    #subsection(title: "Ordering, shutdown and callback placement")[
      #points(
        [Admitted events from one producer to the same destination execute FIFO. Interleaving across producers is unspecified, and events split across routes or route changes have no relative-order guarantee.],
        [Native handlers run in the forwarder process, serially for forwarded occurrences. A blocking handler blocks the forwarder, consumes one executing slot and causes later producers to fill or exceed capacity without blocking those producers.],
        [Catchable callback failures retain native removal and allow the forwarder to continue. A handler linked to a failing process, or an untrappable kill, can still terminate the forwarder; isolation moves that execution risk to a supervised process rather than making callbacks harmless.],
        [Shutdown does not drain the queue or wait for effects triggered by handlers. Pending work is lost, and restart snapshots leftover name-wide in-flight count as lost before starting fresh admission counters.],
        [Forwarding offers no acknowledgement, retry, deadline or cancellation operation. Applications use separate delivery infrastructure when durable or confirmed export is required.],
      )
    ]
    #subsection(title: "Drop reports and accounting limits")[
      #points(
        [The native event name is `[sinal, forwarder, dropped]`. Its integer measurements are rejected, lost and unavailable; metadata carries the forwarder name under forwarder.],
        [Rejected counts capacity refusals, unavailable counts absent targets, and lost estimates admitted work remaining from the previous incarnation. All three diagnostic slots are shared by every Forwarder value built from one name.],
        [Startup drains all three counts and queues a report only when any is nonzero. A running drop drain exchanges rejected and unavailable to zero and reports them with lost set to zero.],
        [A local per-incarnation flag coalesces drop notifications into one pending notice. It is cleared before draining so a racing refusal can schedule the next notice; a delayed old notification cannot target the replacement or change its flag.],
        [Reports execute native telemetry directly in the forwarder and bypass every route, including the empty prefix. A slow report observer can block the forwarder, but report emission cannot recursively create a forwarded drop.],
        [Drained counts are not restored if the process dies before reporting them. If the forwarder never starts again, unavailable drops may remain unreported for the rest of the node lifetime; direct Refusal is the only immediate signal to an explicit caller.],
      )
      #behavior(title: "Drop reporting cannot recurse through a route", area: "Bounded forwarding and routing", level: "boundary")[
        #given[a drop drain contains a nonzero diagnostic count]
        #when[the running incarnation reports that drain]
        #then[the report bypasses route selection and exposes exactly the drained counts]
        #then[reporting the drop does not itself require forwarder admission]
      ]
    ]
    #subsection(title: "Node-wide prefix routes")[
      #points(
        [route binds a trusted prefix to a forwarding closure in node-wide persistent_term. Empty prefix matches every ordinary event; longest prefix wins, and writing the same prefix replaces its destination.],
        [Route writers serialize through a node-local lock and publish one sorted route-list value. Readers perform one persistent_term lookup and scan longest-first without acquiring that lock; route count and scan length are unbounded.],
        [Unroute removes exactly one prefix. Later events select a shorter matching route or execute inline, while events already handed to the old forwarder may finish after those later inline events.],
        [Persistent-term replacement or removal can impose node-wide runtime cost. Route changes belong to application startup/shutdown or rare explicit reconfiguration rather than each request.],
        [`sinal.emit` returns Nil and discards a selected forwarder's typed refusal after recording it. `forwarder.emit` ignores routes and returns Refusal directly; spans and drop reports always remain native inline operations.],
        [No default forwarder application starts itself. An application supervises its chosen process before routing, then removes its route as part of shutdown; a route to an unavailable process keeps dropping rather than silently changing execution placement.],
      )
      #behavior(title: "Longest-prefix routing selects one destination", area: "Bounded forwarding and routing", level: "boundary")[
        #given[several configured route prefixes match an emitted name]
        #when[ordinary emission resolves the route]
        #then[the longest matching prefix selects the forwarder]
        #then[one selected destination receives the admission attempt]
      ]
      #points(
        [#adr(3) records the ordinary route-aware path and refusal policy. The SSO Portal consumer supervises a forwarder and routes HTTP Gun's prefix once; Grind independently owns runtime-local forwarders and can retain its direct refusal boundary.],
      )
    ]
    #notes(title: "Implementation and operational evidence")[#lnk("../../src/sinal/forwarder.gleam")[Forwarder], #lnk("../../src/sinal_forwarder_ffi.erl")[incarnation publication and atomics], #lnk("../../src/sinal/internal/route.gleam")[route port], #lnk("../../test/forwarder_test.gleam")[capacity/restart tests], #lnk("../../test/forwarder_route_test.gleam")[route tests] and #lnk("../../dev/check_forwarder.py")[barrier race probes] own these guarantees.]
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
        [Erlang/BEAM is the supported target; JavaScript is unsupported because the boundary uses native telemetry, maps, references, OTP processes, ETS, atomics and persistent_term. The package requires Gleam 1.18 or newer and supports telemetry 1.4.2 through later 1.x releases under the declared dependency range.],
        [The package's oracle is telemetry 1.4.2 at upstream revision 7baf8085e406d5ae9e43b284d7c866742ae04b28. The manifest and CI toolchain are explicit build inputs rather than a claim that every supported patch or OTP release has been exercised.],
        [Handler registry and routes belong to one node. Atom definitions and name-wide diagnostic counters can remain for its lifetime; attachment closure retention lasts until native removal, while queued event terms remain until dispatch or process death.],
        [No event payload size, native-map size, route-count, handler-count, capture-size or collector-history limit is enforced. Only correlation bytes, definition spelling and forwarder occurrence count have the explicit bounds described here.],
        [Security depends on source-trusted atom definitions and safe caller metadata. Native failure configuration exposes closures, and arbitrary exception terms can contain application details; exporters must select and redact safe fields under their own contract.],
        [Native telemetry's handler-table persistence is an in-memory runtime optimization rather than storage durability. There is no persistence adapter, transaction log or node-restart recovery layer to model.],
      )
    ]
  ])

  #section(title: "Verification and maintenance", lead: "Native parity and public consumers verify the contracts at their real boundaries.", body: [
    #answers(title: "Verification contracts", accent: accent,
      responsibility: [Keep native behavior, typed boundaries, race guarantees and documentation examples executable.],
      interface: [Package tests, focused behavior and stress programs, peer-VM startup checks, forwarder race harness, formatter and design gate.],
      interactions: [Native telemetry is the differential oracle; consumer packages exercise public imports and real application types.],
      invariants: [Checks must use the declared toolchain; barrier synchronization governs race evidence; README snippets match their executable source exactly.],
      failure: [Behavior mismatch, stale docs, missing public module docs, race-probe failure or invalid/stale design render fails its owning check; performance measurements are observations rather than universal guarantees.],
    )
    #subsection(title: "Native oracle and acceptance obligations")[
      #points(
        [The oracle provenance records upstream revision, Hex checksum, Apache-2.0 license and relevant case mappings. Its function-name history is not the current API; executable tests and this layer state the active contract.],
        [Native parity covers emitting PID, synchronous completion, slow-handler blocking, unspecified handler order, concurrent producers, duplicate ids, repeated detach and storage migration through native persist. Tests compare exact names and maps with raw handlers on Sinal emission and Sinal handlers on raw emission.],
        [Typed boundary tests cover separate same-shaped descriptors, unknown-field tolerance, malformed maps, arbitrary terms, definition collisions, codec roundtrips and enum completeness. Decode retention is an intentional documented deviation from mapping every malformed payload to a native callback exception.],
        [Scope tests cover ordinary values, business Error values, refusal rollback, catchable work/acquisition exceptions, reverse cleanup, reporter failure, prior handler removal, nested fresh identities and already selected callbacks after detach.],
        [Span tests cover reserved keys, distinct event roles, native integer timing, explicit time conversion, context equality within an invocation, distinct contexts across invocations, normal business errors, nested ordering and original error/exit/throw evidence.],
        [Forwarder tests cover blocked-handler admission, refusal/report coalescing, missing targets, FIFO, killed-incarnation loss and safe capacity after restart. Disposable source-copy probes synchronize publication, delayed admitted send and delayed drop-notice races without adding production test hooks.],
        [Public consumers must complete a common task, configure distinct advanced behavior, supply their own records/errors and handle failures through public imports. SSO Portal proves supervised routing and labelled optional handlers; support_desk proves required application correlation plus independent package descriptors; Grind proves package-owned forwarding.],
      )
    ]
    #subsection(title: "Operational checks and generated documentation")[
      #points(
        [#lnk("../testing.md")[Testing guidance] names repeatable package-scoped commands. The full package runtime gate and design gate have separate purposes; neither proves the other's semantic claims.],
        [README examples remain coupled to test/readme_example_test.gleam: the test extracts every Gleam fence and requires its exact text to appear in the executable source. Durable prose cleanup preserves those quoted snippets or updates their executable matcher in the same authorized change.],
        [Public modules must begin with a module doc. Documentation and native-map accessor tests prevent a convenient facade from hiding operational placement or forcing test-only native registration.],
        [Benchmark and stress programs remain reproducible evidence. Benchmark results depend on VM, scheduler, load and compiler; no fixed nanosecond rate or universal zero-overhead promise belongs to the design.],
        [Nix supplies the declared Gleam/OTP/rebar3/Python toolchain and formatting. Conventional formatter, hook and CI configuration are standard infrastructure; the pinned design bundle renders one PDF and checks semantic references and artifact integrity.],
        [#lnk("../COVERAGE.md")[Coverage] accounts for every meaningful production, test, FFI, operational and tooling part. The layer owns architecture; README and module docs own usage; ADRs own rationale and historical provenance.],
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

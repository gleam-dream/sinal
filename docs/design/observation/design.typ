#import "../.render/designlib.typ": *

#let title = [Observation]
#let accent = "teal"

#let body = [
  #section(title: "Foundation", lead: "Typed definitions, registrations, scopes, correlations and spans share the native BEAM contract.", body: [
    #goal(title: "Emit and observe caller-owned Gleam values")[One event definition binds a native name to independent measurement and metadata codecs. Producers and observers reuse it without erasing their application records.]
    #goal(title: "Interoperate with native telemetry producers and handlers")[Erlang and Elixir code receives atom-list names and native maps. Foreign maps are decoded before typed handlers run.]
    #goal(title: "Provide explicit observation lifetimes")[Applications own long-lived attachments, scoped groups and native spans. Each lifetime states what it retains and what it releases.]
    #invariant(title: "Typed handlers receive decoded declared values", enforcement: "mechanism")[Both maps must decode through the selected event before its typed callback runs. A malformed map is never passed as a partially decoded application value.]
    #invariant(title: "Work exceptions retain their original identity", enforcement: "mechanism")[A catchable work error, exit or throw retains class, reason and stacktrace through scoped cleanup and native span execution. Cleanup reporting cannot replace a work exception.]
    #invariant(title: "Atom-producing definitions come from trusted source", enforcement: "convention")[Event names, route prefixes and field keys must be source definitions (see #term("term-source-definition")). Grammar checks reject invalid spelling but cannot prove trust or bound the number of valid names.]
    #principle(title: "Preserve native ownership at the observation boundary")[The native registry owns handler selection and inline execution. Sinal supplies typed definitions and explicit application-selected isolation.]
  ])

  #pending-ledger(
    pending-entry(title: "Recover an attachment after an uncertain native call", kind: "ruling", since: "2026-10-06")[Native registry calls can raise or time out after their result becomes uncertain. A scope can clean up only registrations whose acquisition returned a handle, and automatic identifiers stay hidden from the caller when acquisition raises. No generation token, cancellation protocol or uncertain-acquisition recovery contract is specified.],
    pending-entry(title: "Trace parentage and propagation requirements", kind: "ruling", since: "2026-10-06", adr: [#adr(7)])[A correlation can carry a trace identifier, but neither it nor a native span context carries parent-child semantics. Causation fields and OpenTelemetry propagation remain requirements to settle when a tracing adapter is designed.],
  )

  #section(title: "Observation model", lead: "Definitions, registrations and recorded occurrences have distinct ownership.", body: [
    #subsection(title: "Concept and relationship census")[Eight model subjects describe its values and live ownership: event definition, field codec, correlation, subscription, attachment, scope, span definition and span invocation. The #ctx("forwarding") context owns the forwarder incarnation and route table. Lifecycle states describe observable control flow rather than requiring those exact runtime records.
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
        ), edges: (
          (from: "event", to: "fields", relation: "dependency", label: "1 : 2 codecs"),
          (from: "fields", to: "correlation", relation: "dependency", label: "0..n : 0..1 field values"),
          (from: "subscription", to: "event", relation: "dependency", label: "n : n selected definitions"),
          (from: "attachment", to: "subscription", relation: "dependency", label: "0..n : 1 installed description"),
          (from: "scope", to: "attachment", relation: "dependency", label: "1 : 0..n acquired registrations"),
          (from: "span", to: "event", relation: "dependency", label: "1 : 3 event roles"),
          (from: "invocation", to: "span", relation: "dependency", label: "0..n : 1 definition"),
        ), caption: [Edges describe typed definitions and ownership, rather than delivery order. A descriptor sharing a raw name with another descriptor does not establish global schema agreement.],
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
        [Span Completion], [The work result, extra stop measurements and independent stop metadata.],
        [Span event records], [Start/stop/exception measurements and metadata retain separate role types; native time wrappers and context stay opaque.],
        [ExceptionKind and TimeUnit], [Error/Exit/Throw classify native exceptions; Native/Nanosecond/Microsecond/Millisecond/Second select conversion units.],
      ))
      #points(
        [There is no stored business aggregate, journaled command, persisted lifecycle or transactional event stream. Observations are transient occurrences; the native registry is node-local runtime state.],
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
        [Here constructor labels preserve the route/status relationship despite the opposite declaration order. Named binding prevents a silent swap of two same-typed fields; #adr(6) records the choice.],
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
    #notes(title: "Implementation and behavioral evidence")[#lnk("../../../src/sinal/fields.gleam")[Fields], #lnk("../../../src/sinal/internal/name.gleam")[name admission], #lnk("../../../src/sinal/internal/emit.gleam")[emit diagnostics], #lnk("../../../test/sinal_test.gleam")[codec tests] and #lnk("../../../test/decode_failure_test.gleam")[enum completeness tests] own the current executable boundary.]
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
        [The ordinary subscription logs a decode warning and retains the registration. A custom failure observer that raises converts even a malformed-data path into native callback failure; #adr(4) records the retained-handler rule.],
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
    #notes(title: "Implementation and behavioral evidence")[#lnk("../../../src/sinal.gleam")[Public dispatch and registration], #lnk("../../../src/sinal_ffi.erl")[native registry boundary], #lnk("../../../test/sinal_test.gleam")[native interoperability and failure tests] and #lnk("../../../test/sinal_telemetry_start_test.gleam")[fresh-VM startup test] describe this boundary without claiming unknown-call recovery.]
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
    #notes(title: "Implementation and behavioral evidence")[#lnk("../../../src/sinal.gleam")[Subscription acquisition], #lnk("../../../src/sinal_scope_ffi.erl")[exception and cleanup shim], #lnk("../../../test/api_control_test.gleam")[heterogeneous scope tests] and #lnk("../../../test/sinal_test.gleam")[scope and in-flight detach tests] own the observable cases.]
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
    #notes(title: "Implementation and public consumer evidence")[#lnk("../../../src/sinal/correlation.gleam")[Correlation] and #lnk("../../../test/correlation_test.gleam")[byte bounds and field interoperability] define the package boundary. The support_desk consumer carries a required ticket correlation across Fabric, Saga, HTTP Gun and LLM Wire; SSO Portal uses optional package values and labelled handlers rather than inferring identity from execution processes.]
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
    #notes(title: "Implementation and behavioral evidence")[#lnk("../../../src/sinal/span.gleam")[Typed native spans], #lnk("../../../src/sinal_ffi.erl")[native span adapter], #lnk("../../../test/sinal_test.gleam")[terminal, context and native-term tests] and #lnk("../../../test/api_control_test.gleam")[explicit unit and malformed timing tests] retain the native semantics.]
  ])
]

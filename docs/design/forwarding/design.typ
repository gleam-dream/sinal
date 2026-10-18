#import "../.render/designlib.typ": *

#let title = [Forwarding]
#let accent = "violet"

#let body = [
  #section(title: "Foundation", lead: "Applications choose process separation, and each running incarnation owns admission.", body: [
    #goal(title: "Separate handler execution from the producer")[An application can route event-name prefixes to a supervised forwarder process. A routed producer hands the occurrence over and continues without waiting for handlers.]
    #goal(title: "Bound admitted occurrences without blocking producers")[A forwarder admits at most its capacity and refuses the rest immediately. Refusals are counted and reported as diagnostics.]
    #no-goal(title: "Forwarding offers no delivery guarantee")[A forwarder performs no acknowledgement, retry, drain, deadline or cancellation. Durable or confirmed export belongs to separate infrastructure.]
    #invariant(title: "Admission never exceeds one incarnation's capacity", enforcement: "mechanism")[A forwarder's capacity includes queued and executing events. Its published destination and admission counter belong to the same running lifetime.]
    #invariant(title: "A refused routed occurrence never runs inline", enforcement: "mechanism")[A full or unpublished destination refuses the occurrence and counts it. The refusal never falls back to synchronous delivery in the producer.]
    #principle(title: "Make operational limits visible to callers")[Process placement, resource retention, absence, refusal and cleanup remain observable contracts. A convenient constructor does not imply delivery, quiescence or durability.]
  ])

  #section(title: "Forwarder and route model", lead: "A forwarder value survives restarts, while admission authority belongs to one running incarnation.", body: [
    #subsection(title: "Forwarder incarnation and route lifetime")[Admission authority belongs to the running incarnation. The application owns route configuration and supervision; a forwarder value survives an incarnation without carrying its admission rights.
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
    #subsection(title: "Public sums")[Refusal and drop reports classify delivery limits; the diagnostic counts are estimates rather than receipts.
      #md-table(2, (
        [Public type], [Meaning and cases],
        [Forwarder Refusal], [CapacityExceeded; ForwarderUnavailable. Both mean the occurrence was refused rather than retried.],
        [Dropped and DroppedMetadata], [Rejected, lost and unavailable counts plus the forwarder's native name as text. Counts are diagnostic estimates.],
      ))
    ]
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
    #notes(title: "Implementation and operational evidence")[#lnk("../../../src/sinal/forwarder.gleam")[Forwarder], #lnk("../../../src/sinal_forwarder_ffi.erl")[incarnation publication and atomics], #lnk("../../../src/sinal/internal/route.gleam")[route port], #lnk("../../../test/forwarder_test.gleam")[capacity/restart tests], #lnk("../../../test/forwarder_route_test.gleam")[route tests] and #lnk("../../../dev/check_forwarder.py")[barrier race probes] own these guarantees.]
  ])
]

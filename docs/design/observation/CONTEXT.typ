#let terms = (
  (slug: "term-event", title: [Event], body: [An immutable typed definition of one telemetry name and its measurement and metadata shapes. A definition is distinct from an occurrence emitted under that name.]),
  (slug: "term-source-definition", title: [Source definition], body: [An event name, route prefix or field key written in application source and validated against the name grammar. Source definitions are the only input that may create atoms.

    _Avoid_: dynamic name — a name built from input creates unbounded permanent atoms.]),
  (slug: "term-fields", title: [Fields], body: [A bidirectional description of the declared keys in one native telemetry map and the caller value represented by those keys.]),
  (slug: "term-measurements", title: [Measurements], body: [The numeric or application-defined values recorded as the first map of a telemetry occurrence.]),
  (slug: "term-metadata", title: [Metadata], body: [The descriptive and identifying values recorded as the second map of a telemetry occurrence.]),
  (slug: "term-native-registry", title: [Native registry], body: [The node-wide `:telemetry` handler table that selects and runs registered callbacks. Sinal installs typed callbacks into it and creates no registry of its own.]),
  (slug: "term-subscription", title: [Subscription], body: [An immutable registration description whose typed callback, failure observer, and selected event definitions are already bound.]),
  (slug: "term-handler-identifier", title: [Handler identifier], body: [The node-local native identity of one registration. It is either a fresh generated value or a nonempty stable string chosen by the caller.]),
  (slug: "term-attachment", title: [Attachment], body: [A handle naming one native handler registration. A copied handle retains the same identifier after that registration disappears.]),
  (slug: "term-handler-failure", title: [Handler failure], body: [A malformed measurement, malformed metadata, or caller-defined error returned by a typed handler. Unexpected exceptions are outside this sum.]),
  (slug: "term-subscription-plan", title: [Subscription plan], body: [An ordered group of subscriptions with a reporter for cleanup failures that accompany a catchable exception.]),
  (slug: "term-subscription-scope", title: [Subscription scope], body: [One acquisition, work, and cleanup lifetime for a subscription plan. It owns the registrations it successfully acquired.]),
  (slug: "term-cleanup-failure", title: [Cleanup failure], body: [A failed detach attempt during scope cleanup, retained with its zero-based plan index. It never replaces the work value or the work exception.]),
  (slug: "term-correlation", title: [Correlation], body: [An opaque UTF-8 value of one to 128 bytes identifying an application-selected unit of work across observations. It is distinct from a package's own invocation identifier.]),
  (slug: "term-span", title: [Span], body: [An immutable definition of the start, stop, and exception observations surrounding one call of instrumented work.]),
  (slug: "term-span-completion", title: [Span completion], body: [The normal result of instrumented work together with its extra stop measurements and independent stop metadata. A returned application error is a normal completion.]),
  (slug: "term-span-context", title: [Span context], body: [A native identity shared by the start and terminal observations of one span invocation. It supplies equality rather than trace parentage.]),
)

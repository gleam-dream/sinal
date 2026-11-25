# Detach owner-bound registrations from a supervised janitor

<a id="adr-0016"></a>

- A registration can be bound to an owner process. An application-supervised janitor process installs the handler, monitors the owner and detaches the handler when the owner exits. `attach` and an unbound `with_subscriptions` keep cleaning up in the calling process and start no process.
- Cleanup in the registering process runs only while that process runs. An exit signal from a linked process, a supervisor shutdown or a kill terminates a process that does not trap exits without running its cleanup, and the handler then stays in the node-wide registry, with everything its closure captured, for the life of the node. Only another process can observe that exit, so the choice was which process.
- A process spawned by each attach was rejected: nothing would supervise it, and it would add one hidden process per registration. A janitor started by the library on first use was rejected because Sinal allocates no process the application did not ask for; the forwarder already follows that rule. Trapping exits in the owner was rejected because it changes how the caller's process reacts to its links.
- The janitor installs the handler itself. Installing in the caller and reporting to the janitor afterwards would leave an interval in which the owner can exit after the janitor handled its exit and before the handler is attached.
- Tracking is state of the janitor process and is lost when the janitor exits. Rebuilding it from the native registry would require every owner-bound identifier to encode its owner, which stable `with_id` identifiers cannot do.

# Sinal usage examples

Compiled and run examples of the public API. Each module under `src/usage/` shows one topic and has a `run` function that checks what the example does, so a change to the library that breaks an example fails the gate.

| Module                        | Shows                                                                       |
| ----------------------------- | --------------------------------------------------------------------------- |
| `usage/observe.gleam`         | Define an event, observe it, emit and detach                                |
| `usage/records.gleam`         | Records as measurements and metadata, enums and the every-constructor check |
| `usage/handlers.gleam`        | A fallible handler with a failure observer and a stable id                  |
| `usage/scopes.gleam`          | Subscriptions that exist only while work runs                               |
| `usage/spans.gleam`           | A native span around a unit of work                                         |
| `usage/forwarding.gleam`      | Prefix routing to a supervised forwarder and a package-owned forwarder      |
| `usage/correlation_ids.gleam` | Optional and required correlation values                                    |

Run from this directory:

```sh
nix develop ../.. --command gleam run   # run every example once
nix develop ../.. --command gleam test  # run each as a test
```

README consistency is reviewed manually. The gate profiles in [AGENTS.md](../../AGENTS.md) run the examples after the package tests.
